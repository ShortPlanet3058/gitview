import XCTest
@testable import GitViewGit

final class CodeSearchParserTests: XCTestCase {

    /// Real `git grep -z -n` shape: path and line number are NUL-separated, so a path
    /// containing a colon cannot be mis-split the way `path:line:text` would be.
    func testParsesGrepOutput() {
        let output = "Sources/A.swift\u{0}85\u{0}    private func responseBody() -> ByteBuffer {\n"
                   + "Sources/B.swift\u{0}23\u{0}        var buffer = ByteBufferAllocator()\n"
        let matches = CodeSearchParser.parseGrep(output, limit: 100)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].path, "Sources/A.swift")
        XCTAssertEqual(matches[0].line, 85)
        XCTAssertEqual(matches[0].text, "private func responseBody() -> ByteBuffer {",
                       "leading indentation is trimmed for display")
        XCTAssertEqual(matches[0].id, "Sources/A.swift:85")
    }

    func testPathContainingAColonSurvives() {
        let output = "Sources/odd:name.swift\u{0}7\u{0}let x = 1\n"
        XCTAssertEqual(CodeSearchParser.parseGrep(output, limit: 10).first?.path, "Sources/odd:name.swift")
    }

    func testTextContainingAColonIsKeptWhole() {
        let output = "A.swift\u{0}1\u{0}let url = \"https://example.com:8080\"\n"
        XCTAssertEqual(CodeSearchParser.parseGrep(output, limit: 10).first?.text,
                       "let url = \"https://example.com:8080\"")
    }

    func testLimitIsRespected() {
        let output = (1...50).map { "A.swift\u{0}\($0)\u{0}line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(CodeSearchParser.parseGrep(output, limit: 10).count, 10)
    }

    func testGarbageIsSkipped() {
        let output = "no separators here\nA.swift\u{0}notanumber\u{0}x\nB.swift\u{0}2\u{0}ok\n"
        let matches = CodeSearchParser.parseGrep(output, limit: 10)
        XCTAssertEqual(matches.map(\.path), ["B.swift"])
    }

    func testEmpty() { XCTAssertTrue(CodeSearchParser.parseGrep("", limit: 10).isEmpty) }

    func testParsesPickaxeHeaders() {
        let output = "5bf841dd\u{1F}George Barnett\u{1F}2025-11-24T11:13:50Z\u{1F}Drop and reacquire lock (#3452)\n"
                   + "ee67a96b\u{1F}Cory Benfield\u{1F}2025-07-18T09:13:00+01:00\u{1F}Call channel initializer (#3309)"
        let commits = CodeSearchParser.parseCommitHeaders(output)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].author, "George Barnett")
        XCTAssertEqual(commits[0].subject, "Drop and reacquire lock (#3452)")
        XCTAssertTrue(commits[0].fileChanges.isEmpty, "the pickaxe log deliberately carries no diff")
        XCTAssertEqual(commits[1].date, ISO8601DateFormatter().date(from: "2025-07-18T09:13:00+01:00"))
    }

    func testSubjectMayContainTheFieldSeparatorlessCharacters() {
        let output = "aaa\u{1F}Ann\u{1F}2024-01-01T00:00:00Z\u{1F}fix: a|b — done"
        XCTAssertEqual(CodeSearchParser.parseCommitHeaders(output).first?.subject, "fix: a|b — done")
    }
}
