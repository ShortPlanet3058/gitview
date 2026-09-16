import XCTest
@testable import GitViewGit

final class BlameParserTests: XCTestCase {
    /// Shape of real `git blame --line-porcelain` output: a full header per line, with the
    /// content line last and tab-prefixed.
    private func block(sha: String, author: String, time: Int, content: String) -> String {
        """
        \(sha) 1 1 1
        author \(author)
        author-mail <\(author.lowercased())@example.com>
        author-time \(time)
        author-tz +0100
        committer \(author)
        committer-mail <\(author.lowercased())@example.com>
        committer-time \(time)
        committer-tz +0100
        summary a commit
        filename a.swift
        \t\(content)
        """
    }

    func testCountsLinesPerAuthor() {
        let output = [
            block(sha: "a", author: "Ann", time: 1_700_000_000, content: "one"),
            block(sha: "b", author: "Ann", time: 1_700_000_100, content: "two"),
            block(sha: "c", author: "Bob", time: 1_600_000_000, content: "three"),
        ].joined(separator: "\n")

        let blame = BlameParser.parse(output, path: "a.swift")
        XCTAssertEqual(blame.totalLines, 3)
        XCTAssertEqual(blame.authors.map(\.name), ["Ann", "Bob"])
        XCTAssertEqual(blame.authors[0].lines, 2)
        XCTAssertEqual(blame.authors[0].share, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(blame.primary?.name, "Ann")
        XCTAssertEqual(blame.oldestLine, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(blame.newestLine, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(blame.authors[0].newestLine, Date(timeIntervalSince1970: 1_700_000_100))
    }

    /// `author-mail`, `author-time` and `author-tz` all begin with "author" — only the bare
    /// `author ` line names a person.
    func testAuthorHeaderIsNotConfusedWithItsSiblings() {
        let output = block(sha: "a", author: "Ann", time: 1_700_000_000, content: "x")
        let blame = BlameParser.parse(output, path: "a.swift")
        XCTAssertEqual(blame.authors.count, 1)
        XCTAssertEqual(blame.authors.first?.name, "Ann")
    }

    func testEmptyOutput() {
        let blame = BlameParser.parse("", path: "a.swift")
        XCTAssertEqual(blame.totalLines, 0)
        XCTAssertTrue(blame.authors.isEmpty)
        XCTAssertNil(blame.primary)
        XCTAssertNil(blame.oldestLine)
    }

    func testAuthorNamesWithSpacesAndUnicode() {
        let output = block(sha: "a", author: "Mirza Učanbarlić", time: 1_700_000_000, content: "x")
        XCTAssertEqual(BlameParser.parse(output, path: "a.swift").authors.first?.name, "Mirza Učanbarlić")
    }
}
