import XCTest
@testable import GitViewGit

final class DiffParserTests: XCTestCase {

    /// Captured from `git show --format= --unified=2 -- edit.txt`.
    private let modified = """
    diff --git a/edit.txt b/edit.txt
    index b2f931a..9642008 100644
    --- a/edit.txt
    +++ b/edit.txt
    @@ -1,5 +1,6 @@
     one
    -two
    +TWO
     three
     four
     five
    +six
    """

    func testLineNumbersAdvanceOnTheCorrectSide() {
        let diff = DiffParser.parse(modified, path: "edit.txt")
        XCTAssertEqual(diff.hunks.count, 1)
        let lines = diff.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .deletion, .addition, .context, .context, .context, .addition])

        // "one" is line 1 on both sides.
        XCTAssertEqual(lines[0].oldNumber, 1)
        XCTAssertEqual(lines[0].newNumber, 1)
        // A removed line has an old number and no new one; an added line the reverse.
        XCTAssertEqual(lines[1].oldNumber, 2)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertNil(lines[2].oldNumber)
        XCTAssertEqual(lines[2].newNumber, 2)
        // After the swap both sides continue from 3.
        XCTAssertEqual(lines[3].oldNumber, 3)
        XCTAssertEqual(lines[3].newNumber, 3)
        // The appended line exists only on the new side, at 6.
        XCTAssertEqual(lines[6].newNumber, 6)
        XCTAssertNil(lines[6].oldNumber)
    }

    func testCountsAndText() {
        let diff = DiffParser.parse(modified, path: "edit.txt")
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.hunks[0].lines[2].text, "TWO", "the marker is stripped, the text is not")
        XCTAssertFalse(diff.isNew)
        XCTAssertFalse(diff.isDeleted)
        XCTAssertFalse(diff.isBinary)
    }

    func testNewFile() {
        let output = """
        diff --git a/added.txt b/added.txt
        new file mode 100644
        index 0000000..858e580
        --- /dev/null
        +++ b/added.txt
        @@ -0,0 +1,2 @@
        +brand new
        +second line
        """
        let diff = DiffParser.parse(output, path: "added.txt")
        XCTAssertTrue(diff.isNew)
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 0)
        XCTAssertEqual(diff.hunks[0].lines.first?.newNumber, 1)
    }

    func testDeletedFile() {
        let output = """
        diff --git a/removed.txt b/removed.txt
        deleted file mode 100644
        index 286c5f5..0000000
        --- a/removed.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        """
        let diff = DiffParser.parse(output, path: "removed.txt")
        XCTAssertTrue(diff.isDeleted)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.hunks[0].lines.first?.oldNumber, 1, "a count-less header means one line")
    }

    /// The `\\` line annotates the line above it; it is not a line of the file.
    func testNoNewlineMarkerAttachesToThePreviousLine() {
        let output = """
        --- a/nonewline.txt
        +++ b/nonewline.txt
        @@ -1 +1 @@
        -no trailing newline
        \\ No newline at end of file
        +no trailing newline CHANGED
        \\ No newline at end of file
        """
        let diff = DiffParser.parse(output, path: "nonewline.txt")
        let lines = diff.hunks[0].lines
        XCTAssertEqual(lines.count, 2, "the two marker lines are not lines of their own")
        XCTAssertTrue(lines[0].missingTrailingNewline)
        XCTAssertTrue(lines[1].missingTrailingNewline)
        XCTAssertEqual(lines[0].text, "no trailing newline")
    }

    func testBinaryFileHasNoHunks() {
        let output = """
        diff --git a/data.bin b/data.bin
        index 57ac8df..5355707 100644
        Binary files a/data.bin and b/data.bin differ
        """
        let diff = DiffParser.parse(output, path: "data.bin")
        XCTAssertTrue(diff.isBinary)
        XCTAssertTrue(diff.hunks.isEmpty)
        XCTAssertFalse(diff.isEmpty, "binary is not the same as no change")
    }

    func testRename() {
        let output = """
        diff --git a/old.txt b/new.txt
        similarity index 90%
        rename from old.txt
        rename to new.txt
        --- a/old.txt
        +++ b/new.txt
        @@ -1 +1 @@
        -a
        +b
        """
        let diff = DiffParser.parse(output, path: "new.txt")
        XCTAssertTrue(diff.isRename)
        XCTAssertEqual(diff.oldPath, "old.txt")
        XCTAssertEqual(diff.path, "new.txt")
    }

    func testMultipleHunksKeepTheirOwnStartsAndSection() {
        let output = """
        --- a/a.swift
        +++ b/a.swift
        @@ -10,3 +10,3 @@ func first() {
         x
        -y
        +Y
        @@ -100,2 +100,3 @@ func second() {
         p
        +q
        """
        let diff = DiffParser.parse(output, path: "a.swift")
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertEqual(diff.hunks[0].oldStart, 10)
        XCTAssertEqual(diff.hunks[0].section, "func first() {")
        XCTAssertEqual(diff.hunks[1].newStart, 100)
        XCTAssertEqual(diff.hunks[1].section, "func second() {")
        XCTAssertEqual(diff.hunks[1].lines.last?.newNumber, 101)
    }

    func testBlankContextLineIsKept() {
        // git writes a blank context line as a single space; some tools drop the space.
        // The fixture ends with a newline exactly as real output does.
        let output = "--- a/a\n+++ b/a\n@@ -1,3 +1,3 @@\n a\n\n-b\n+B\n"
        let diff = DiffParser.parse(output, path: "a")
        XCTAssertEqual(diff.hunks[0].lines.map(\.kind), [.context, .context, .deletion, .addition])
        XCTAssertEqual(diff.hunks[0].lines[1].text, "")
    }

    /// Real git output is newline-terminated; that terminator must not become a line.
    func testTrailingNewlineDoesNotAddAPhantomLine() {
        let withNewline = "--- a/a\n+++ b/a\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"
        let without = String(withNewline.dropLast())
        XCTAssertEqual(DiffParser.parse(withNewline, path: "a").hunks[0].lines.count, 3)
        XCTAssertEqual(DiffParser.parse(without, path: "a").hunks[0].lines.count, 3)
    }

    func testLineBudgetTruncatesRatherThanRenderingEverything() {
        var output = "--- a/big\n+++ b/big\n@@ -1,5000 +1,5000 @@\n"
        output += (1...5000).map { "+line \($0)" }.joined(separator: "\n")
        let diff = DiffParser.parse(output, path: "big", maxLines: 500)
        XCTAssertTrue(diff.truncated)
        XCTAssertLessThanOrEqual(diff.hunks.reduce(0) { $0 + $1.lines.count }, 501)
    }

    func testHunkHeaderVariants() {
        XCTAssertEqual(DiffParser.parseHunkHeader("@@ -1,5 +1,6 @@")?.oldStart, 1)
        XCTAssertEqual(DiffParser.parseHunkHeader("@@ -0,0 +1,2 @@")?.newStart, 1)
        XCTAssertEqual(DiffParser.parseHunkHeader("@@ -12 +12 @@")?.oldStart, 12, "counts may be omitted")
        XCTAssertEqual(DiffParser.parseHunkHeader("@@ -3,2 +4,2 @@ func x() @@ y")?.section, "func x() @@ y")
        XCTAssertNil(DiffParser.parseHunkHeader("not a header"))
    }

    func testEmptyOutput() {
        let diff = DiffParser.parse("", path: "x")
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.additions, 0)
    }
}
