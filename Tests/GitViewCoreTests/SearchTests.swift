import XCTest
@testable import GitViewCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func commit(_ sha: String, _ subject: String, _ author: String = "Ann", daysAgo: Double = 1) -> Commit {
    Commit(sha: sha, author: author, date: now.addingTimeInterval(-daysAgo * 86_400),
           subject: subject, fileChanges: [])
}

private func unit(_ name: String, complexity: Int = 3) -> CodeUnit {
    CodeUnit(filePath: "Sources/\(name).swift", name: name, kind: .function, lineRange: 1...5,
             complexity: complexity, nestingDepth: 0, lineCount: 5)
}

private let corpus = SearchCorpus(
    commits: [
        commit("abc1234def", "Add socket option API for SO_REUSEPORT", "Si Beaumont", daysAgo: 1),
        commit("bbb2222", "Fix socket leak on close", "Ann", daysAgo: 2),
        commit("ccc3333", "Update documentation", "Johannes Weiss", daysAgo: 3),
    ],
    filePaths: ["Sources/NIOPosix/SocketChannel.swift", "Sources/NIOCore/ByteBuffer.swift", "README.md"],
    units: [unit("setOption0", complexity: 19), unit("socketAddress", complexity: 4), unit("write")],
    contributors: [
        Contributor(name: "Si Beaumont", commits: 43, share: 0.1, firstCommit: now, lastCommit: now, isBot: false),
        Contributor(name: "Ann", commits: 5, share: 0.01, firstCommit: now, lastCommit: now, isBot: false),
    ],
    branches: ["main", "socket-fixes"],
    tags: ["2.102.0", "socket-release"])

final class SearchQueryTests: XCTestCase {
    func testBareTerms() {
        let query = SearchQuery.parse("socket option")
        XCTAssertEqual(query.text, "socket option")
        XCTAssertNil(query.author)
        XCTAssertEqual(query.scope, .everything)
    }

    func testAuthorFilter() {
        let query = SearchQuery.parse("author:weiss sockets")
        XCTAssertEqual(query.author, "weiss")
        XCTAssertEqual(query.text, "sockets")
    }

    func testScope() {
        XCTAssertEqual(SearchQuery.parse("in:commits socket").scope, .commits)
        XCTAssertEqual(SearchQuery.parse("in:functions foo").scope, .units)
        XCTAssertEqual(SearchQuery.parse("in:nonsense foo").scope, .everything)
    }

    func testAuthorOnlyIsStillAQuery() {
        let query = SearchQuery.parse("author:ann")
        XCTAssertFalse(query.isEmpty)
        XCTAssertTrue(query.text.isEmpty)
    }

    func testEmpty() {
        XCTAssertTrue(SearchQuery.parse("").isEmpty)
        XCTAssertTrue(SearchQuery.parse("   ").isEmpty)
    }
}

final class SearchEngineTests: XCTestCase {

    func testFindsAcrossEveryKind() {
        let results = SearchEngine.search("socket", in: corpus)
        XCTAssertFalse(results.commits.isEmpty)
        XCTAssertFalse(results.files.isEmpty)
        XCTAssertFalse(results.units.isEmpty)
        XCTAssertFalse(results.branches.isEmpty)
        XCTAssertFalse(results.tags.isEmpty)
        XCTAssertGreaterThan(results.total, 5)
    }

    /// An exact name should beat a prefix, which should beat a match inside a word.
    func testRanking() {
        XCTAssertEqual(SearchEngine.score("write", "write"), 100)
        XCTAssertEqual(SearchEngine.score("writeAndFlush", "write"), 60)
        XCTAssertEqual(SearchEngine.score("buffer.write", "write"), 35)
        XCTAssertEqual(SearchEngine.score("underwriter", "write"), 10)
        XCTAssertNil(SearchEngine.score("nothing", "write"))
    }

    func testBestMatchComesFirst() {
        let results = SearchEngine.search("write", in: corpus)
        XCTAssertEqual(results.units.first?.name, "write", "the exact name outranks the file path")
    }

    func testCommitShaPrefix() {
        let results = SearchEngine.search("abc1234", in: corpus)
        XCTAssertEqual(results.commits.first?.sha, "abc1234def")
    }

    /// Plenty of ordinary English words are valid hex — "added", "decade", "facade" — so
    /// a sha-looking query must still search text rather than only matching commit ids.
    func testHexLookingWordsStillSearchText() {
        XCTAssertTrue(SearchEngine.looksLikeSHA("added"), "a, d, e are all hex digits")
        XCTAssertFalse(SearchEngine.looksLikeSHA("socket"), "s, o, k, t are not")

        let hexWord = SearchCorpus(commits: [commit("ffff1111", "Added a decade of features")])
        let results = SearchEngine.search("added", in: hexWord)
        XCTAssertEqual(results.commits.count, 1, "matched as text even though it looks like a sha")
    }

    /// `author:weiss` must find Johannes Weiss; `author:ann` must not, through "Johannes".
    func testAuthorMatchesWholeWordsNotSubstrings() {
        XCTAssertTrue(SearchEngine.matchesAuthor("Johannes Weiss", "weiss"))
        XCTAssertTrue(SearchEngine.matchesAuthor("Johannes Weiss", "johannes"))
        XCTAssertTrue(SearchEngine.matchesAuthor("Ann", "ann"))
        XCTAssertFalse(SearchEngine.matchesAuthor("Johannes Weiss", "ann"),
                       "the middle of a name is not a match")
        XCTAssertFalse(SearchEngine.matchesAuthor("Si Beaumont", "mont"))
    }

    func testAuthorFilterNarrowsCommits() {
        let results = SearchEngine.search("author:weiss", in: corpus)
        XCTAssertEqual(results.commits.map(\.author), ["Johannes Weiss"])
        XCTAssertTrue(results.files.isEmpty, "an author query is about commits, not paths")
    }

    func testAuthorAndTermTogether() {
        XCTAssertTrue(SearchEngine.search("author:ann socket", in: corpus).commits
            .allSatisfy { $0.author == "Ann" && $0.subject.lowercased().contains("socket") })
        XCTAssertTrue(SearchEngine.search("author:ann documentation", in: corpus).commits.isEmpty)
    }

    func testScopeLimitsSections() {
        let results = SearchEngine.search("in:files socket", in: corpus)
        XCTAssertFalse(results.files.isEmpty)
        XCTAssertTrue(results.commits.isEmpty)
        XCTAssertTrue(results.units.isEmpty)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(SearchEngine.search("SOCKET", in: corpus).total,
                       SearchEngine.search("socket", in: corpus).total)
    }

    func testLimitPerSection() {
        let many = (0..<200).map { commit("s\($0)", "socket change \($0)") }
        let results = SearchEngine.search("socket", in: SearchCorpus(commits: many), limitPerSection: 10)
        XCTAssertEqual(results.commits.count, 10)
    }

    func testEmptyQueryReturnsNothingRatherThanEverything() {
        XCTAssertTrue(SearchEngine.search("", in: corpus).isEmpty)
        XCTAssertTrue(SearchEngine.search("   ", in: corpus).isEmpty)
    }

    func testNoMatches() {
        XCTAssertTrue(SearchEngine.search("zzzznothing", in: corpus).isEmpty)
    }
}
