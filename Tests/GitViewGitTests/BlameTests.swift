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

    func testParsesLinesPreviousHeadersAndAbbreviatedSHARepeats() {
        let sha1 = "1111111111111111111111111111111111111111"
        let sha0 = "0000000000000000000000000000000000000000"
        let output = """
        \(sha1) 10 1 2
        author Alice
        author-time 1700000000
        summary First version
        previous \(sha0) old/a.swift
        filename a.swift
        \tlet first = 1
        \(sha1) 11 2
        \tlet second = 2
        \(sha0) 3 3 1
        author Not Committed Yet
        author-time 1700000200
        summary Draft
        filename a.swift
        \tlet draft = 3
        """

        let blame = BlameParser.parse(output, path: "a.swift", revision: "HEAD")
        XCTAssertEqual(blame.revision, "HEAD")
        XCTAssertEqual(blame.lines.count, 3)

        XCTAssertEqual(blame.lines[0].lineNumber, 1)
        XCTAssertEqual(blame.lines[0].originalLine, 10)
        XCTAssertEqual(blame.lines[0].author, "Alice")
        XCTAssertEqual(blame.lines[0].summary, "First version")
        XCTAssertEqual(blame.lines[0].previousSHA, sha0)
        XCTAssertEqual(blame.lines[0].previousPath, "old/a.swift")
        XCTAssertEqual(blame.lines[0].text, "let first = 1")
        XCTAssertFalse(blame.lines[0].isUncommitted)

        // Second line reuses cached commit metadata for sha1.
        XCTAssertEqual(blame.lines[1].lineNumber, 2)
        XCTAssertEqual(blame.lines[1].author, "Alice")
        XCTAssertEqual(blame.lines[1].summary, "First version")
        XCTAssertEqual(blame.lines[1].text, "let second = 2")

        XCTAssertTrue(blame.lines[2].isUncommitted)
        XCTAssertEqual(blame.lines[2].text, "let draft = 3")
    }

    func testBlameAndFileContentAtHistoricalRevisionOnRealRepo() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitview-blame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = GitRepository(url: root)
        try GitProcess.capture(arguments: ["init", "-q", "-b", "main"], in: root)
        try GitProcess.capture(arguments: ["config", "user.name", "Ann"], in: root)
        try GitProcess.capture(arguments: ["config", "user.email", "ann@example.com"], in: root)

        let fileURL = root.appendingPathComponent("sample.swift")
        try "let v = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try repo.stage(paths: ["sample.swift"])
        let firstSHA = try repo.commit(subject: "First commit")

        try GitProcess.capture(arguments: ["config", "user.name", "Bob"], in: root)
        try GitProcess.capture(arguments: ["config", "user.email", "bob@example.com"], in: root)
        try "let v = 2\nlet extra = 3\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try repo.stage(paths: ["sample.swift"])
        let secondSHA = try repo.commit(subject: "Second commit")

        let latestBlame = try repo.blame(path: "sample.swift")
        XCTAssertEqual(latestBlame.lines.count, 2)
        XCTAssertEqual(latestBlame.lines.first?.author, "Bob")
        XCTAssertEqual(latestBlame.lines.first?.previousSHA, firstSHA)
        XCTAssertEqual(latestBlame.lines.first?.previousPath, "sample.swift")

        let olderBlame = try repo.blame(path: "sample.swift", revision: firstSHA)
        XCTAssertEqual(olderBlame.revision, firstSHA)
        XCTAssertEqual(olderBlame.lines.count, 1)
        XCTAssertEqual(olderBlame.lines.first?.author, "Ann")
        XCTAssertEqual(olderBlame.lines.first?.text, "let v = 1")

        let oldContent = try repo.fileContent(path: "sample.swift", revision: secondSHA)
        XCTAssertFalse(oldContent.isBinary)
        XCTAssertFalse(oldContent.truncated)
        XCTAssertEqual(oldContent.text, "let v = 2\nlet extra = 3\n")
    }
}
