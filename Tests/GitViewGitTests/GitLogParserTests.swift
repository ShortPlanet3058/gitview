import XCTest
@testable import GitViewGit
import GitViewCore

final class GitLogParserTests: XCTestCase {

    /// Feeds a whole log transcript through the splitter + parser.
    private func parse(_ text: String) -> [Commit] {
        var splitter = LineSplitter()
        var parser = GitLogParser()
        splitter.feed(Data(text.utf8)) { parser.consume(line: $0) }
        splitter.finish { parser.consume(line: $0) }
        return parser.finish()
    }

    func testSingleCommitWithTwoFiles() {
        let commits = parse("""
        @@@0123456789abcdef0123456789abcdef01234567\u{1F}Ada Lovelace\u{1F}2024-03-01T09:30:00+01:00
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 1111111..2222222 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -10,0 +11,3 @@
        +one
        +two
        +three
        diff --git a/Sources/B.swift b/Sources/B.swift
        index 3333333..4444444 100644
        --- a/Sources/B.swift
        +++ b/Sources/B.swift
        @@ -5,2 +5,0 @@
        -gone
        -also gone

        """)

        XCTAssertEqual(commits.count, 1)
        let commit = commits[0]
        XCTAssertEqual(commit.sha, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(commit.author, "Ada Lovelace")
        XCTAssertEqual(commit.fileChanges.count, 2)
        XCTAssertEqual(commit.fileChanges[0].path, "Sources/A.swift")
        XCTAssertEqual(commit.fileChanges[0].hunks, [Hunk(newStart: 11, newLineCount: 3)])
        XCTAssertEqual(commit.fileChanges[1].path, "Sources/B.swift")
        XCTAssertEqual(commit.fileChanges[1].hunks, [Hunk(newStart: 5, newLineCount: 0)])
        XCTAssertNil(commit.fileChanges[0].oldPath)
    }

    func testDiffBodyContainingBareHunkMarkersDoesNotSplitCommits() {
        // The whole reason for the @@@ sentinel: patch bodies contain "@@" lines,
        // and added lines can themselves begin with "@@@".
        let commits = parse("""
        @@@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u{1F}Dev\u{1F}2024-01-01T00:00:00Z
        diff --git a/doc.md b/doc.md
        --- a/doc.md
        +++ b/doc.md
        @@ -1,0 +2,2 @@
        +@@ -1,1 +1,1 @@
        +@@@not a commit header
        @@@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\u{1F}Dev\u{1F}2024-01-02T00:00:00Z
        diff --git a/doc.md b/doc.md
        --- a/doc.md
        +++ b/doc.md
        @@ -9,1 +9,1 @@
        -x
        +y

        """)

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].fileChanges[0].hunks, [Hunk(newStart: 2, newLineCount: 2)])
        XCTAssertEqual(commits[1].fileChanges[0].hunks, [Hunk(newStart: 9, newLineCount: 1)])
    }

    func testRenamePopulatesOldPath() {
        let commits = parse("""
        @@@cccccccccccccccccccccccccccccccccccccccc\u{1F}Dev\u{1F}2024-02-02T12:00:00Z
        diff --git a/Old/Name.swift b/New/Name.swift
        similarity index 94%
        rename from Old/Name.swift
        rename to New/Name.swift
        --- a/Old/Name.swift
        +++ b/New/Name.swift
        @@ -3,1 +3,1 @@
        -a
        +b

        """)

        let change = commits[0].fileChanges[0]
        XCTAssertEqual(change.path, "New/Name.swift")
        XCTAssertEqual(change.oldPath, "Old/Name.swift")
    }

    func testUnchangedPathDoesNotReportAsRename() {
        let commits = parse("""
        @@@dddddddddddddddddddddddddddddddddddddddd\u{1F}Dev\u{1F}2024-02-02T12:00:00Z
        diff --git a/Same.swift b/Same.swift
        --- a/Same.swift
        +++ b/Same.swift
        @@ -1,1 +1,1 @@
        -a
        +b

        """)
        XCTAssertNil(commits[0].fileChanges[0].oldPath)
    }

    func testDeletedFileIsDropped() {
        // No counterpart in the current checkout, so no units can ever match it.
        let commits = parse("""
        @@@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\u{1F}Dev\u{1F}2024-02-03T12:00:00Z
        diff --git a/Dead.swift b/Dead.swift
        deleted file mode 100644
        --- a/Dead.swift
        +++ /dev/null
        @@ -1,9 +0,0 @@
        -stuff

        """)
        XCTAssertEqual(commits.count, 1)
        XCTAssertTrue(commits[0].fileChanges.isEmpty)
    }

    func testMergeCommitWithNoDiffIsKept() {
        // git log -p emits no patch for merges. The commit is real; it just has no churn.
        let commits = parse("""
        @@@ffffffffffffffffffffffffffffffffffffffff\u{1F}Dev\u{1F}2024-02-04T12:00:00Z
        @@@1111111111111111111111111111111111111111\u{1F}Dev\u{1F}2024-02-05T12:00:00Z
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -1,1 +1,1 @@
        -a
        +b

        """)
        XCTAssertEqual(commits.count, 2)
        XCTAssertTrue(commits[0].fileChanges.isEmpty)
        XCTAssertEqual(commits[1].fileChanges.count, 1)
    }

    func testSubjectIsCapturedAndMayContainSeparators() {
        let commits = parse("""
        @@@5555555555555555555555555555555555555555\u{1F}Dev\u{1F}2024-02-08T12:00:00Z\u{1F}Fix a | b: handle "x"\u{1F}tail
        """)
        XCTAssertEqual(commits[0].subject, "Fix a | b: handle \"x\"\u{1F}tail")
        XCTAssertEqual(commits[0].author, "Dev")
    }

    func testMissingSubjectIsEmptyNotFailure() {
        let commits = parse("""
        @@@6666666666666666666666666666666666666666\u{1F}Dev\u{1F}2024-02-08T12:00:00Z
        """)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].subject, "")
    }

    func testAuthorNameContainingPipe() {
        let commits = parse("""
        @@@2222222222222222222222222222222222222222\u{1F}Weird | Name\u{1F}2024-02-06T12:00:00Z
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -1,1 +1,1 @@
        -a
        +b

        """)
        XCTAssertEqual(commits[0].author, "Weird | Name")
    }

    func testChunkBoundarySplitsMidLine() {
        // The reader hands us arbitrary byte chunks, not lines. Splitting a hunk header
        // across two chunks must not lose it.
        let text = """
        @@@3333333333333333333333333333333333333333\u{1F}Dev\u{1F}2024-02-07T12:00:00Z
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -10,2 +12,4 @@
        +x

        """
        let bytes = Array(text.utf8)
        for split in stride(from: 1, to: bytes.count, by: 7) {
            var splitter = LineSplitter()
            var parser = GitLogParser()
            splitter.feed(Data(bytes[..<split])) { parser.consume(line: $0) }
            splitter.feed(Data(bytes[split...])) { parser.consume(line: $0) }
            splitter.finish { parser.consume(line: $0) }
            let commits = parser.finish()
            XCTAssertEqual(commits.count, 1, "split at \(split)")
            XCTAssertEqual(commits.first?.fileChanges.first?.hunks,
                           [Hunk(newStart: 12, newLineCount: 4)], "split at \(split)")
        }
    }

    func testDateParsingWithOffset() {
        let commits = parse("""
        @@@4444444444444444444444444444444444444444\u{1F}Dev\u{1F}2024-03-01T09:30:00+01:00
        """)
        // 09:30+01:00 == 08:30 UTC
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_709_281_800))
    }

    func testQuotedPathIsUnescaped() {
        XCTAssertEqual(GitLogParser.unquote("\"a\\\"b.swift\""), "a\"b.swift")
        XCTAssertEqual(GitLogParser.unquote("plain.swift"), "plain.swift")
    }
}

final class ISO8601Tests: XCTestCase {
    func testUTCZulu() {
        XCTAssertEqual(ISO8601.parse("1970-01-01T00:00:00Z"), Date(timeIntervalSince1970: 0))
    }

    func testNegativeOffset() {
        // 12:00-05:00 == 17:00 UTC
        XCTAssertEqual(ISO8601.parse("2024-06-15T12:00:00-05:00"),
                       Date(timeIntervalSince1970: 1_718_470_800))
    }

    func testLeapDay() {
        XCTAssertEqual(ISO8601.parse("2024-02-29T00:00:00Z"),
                       Date(timeIntervalSince1970: 1_709_164_800))
    }

    func testAgreesWithFoundation() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for sample in ["2001-09-09T01:46:40Z", "2023-12-31T23:59:59+13:00", "1999-01-01T00:00:01-08:00"] {
            XCTAssertEqual(ISO8601.parse(sample), formatter.date(from: sample), sample)
        }
    }

    func testRejectsGarbage() {
        XCTAssertNil(ISO8601.parse("not a date"))
        XCTAssertNil(ISO8601.parse(""))
        XCTAssertNil(ISO8601.parse("2024-13-01T00:00:00Z"))
    }
}
