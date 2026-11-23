import XCTest
@testable import GitViewGit

final class FileHistoryParserTests: XCTestCase {
    private func header(_ sha: String, _ author: String, _ date: String, _ subject: String) -> String {
        [sha, author, date, subject].joined(separator: "\u{1F}")
    }

    /// Shape of `git log --follow --numstat --pretty=format:…`: a header line, then the
    /// numstat for that commit.
    func testParsesCommitsWithTheirLineCounts() {
        let output = [
            header("c1ccdbcc", "Victor Debray", "2026-09-15T00:01:23-07:00", "Add channel options (#3689)"),
            "18\t0\tSources/NIOPosix/SocketChannel.swift",
            header("419f57f1", "Joannis Orlandos", "2026-07-07T16:46:28+02:00", "Winsock Fixes (#3433)"),
            "21\t11\tSources/NIOPosix/SocketChannel.swift",
        ].joined(separator: "\n")

        let entries = FileHistoryParser.parse(output, fallbackPath: "Sources/NIOPosix/SocketChannel.swift")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].commit.author, "Victor Debray")
        XCTAssertEqual(entries[0].insertions, 18)
        XCTAssertEqual(entries[0].deletions, 0)
        XCTAssertEqual(entries[0].churn, 18)
        XCTAssertEqual(entries[1].deletions, 11)
        XCTAssertFalse(entries[0].isRename)
    }

    /// The real rename notation, captured from swift-nio: only the moved segment is braced.
    func testBracedRenameOfPartOfThePath() {
        let (previous, current) = FileHistoryParser.resolveRename("Sources/{NIO => NIOPosix}/SocketChannel.swift")
        XCTAssertEqual(previous, "Sources/NIO/SocketChannel.swift")
        XCTAssertEqual(current, "Sources/NIOPosix/SocketChannel.swift")
    }

    func testBracedRenameOfTheFilename() {
        let (previous, current) = FileHistoryParser.resolveRename("Sources/NIO/{Channel.swift => SocketChannel.swift}")
        XCTAssertEqual(previous, "Sources/NIO/Channel.swift")
        XCTAssertEqual(current, "Sources/NIO/SocketChannel.swift")
    }

    func testBareRenameOfTheWholePath() {
        let (previous, current) = FileHistoryParser.resolveRename("old/a.swift => new/b.swift")
        XCTAssertEqual(previous, "old/a.swift")
        XCTAssertEqual(current, "new/b.swift")
    }

    /// A segment appearing or disappearing leaves one side empty.
    func testBracedRenameWithAnEmptySide() {
        let (previous, current) = FileHistoryParser.resolveRename("Sources/{ => Internal}/a.swift")
        XCTAssertEqual(previous, "Sources/a.swift")
        XCTAssertEqual(current, "Sources/Internal/a.swift")
    }

    func testOrdinaryPathIsNotTreatedAsARename() {
        let (previous, current) = FileHistoryParser.resolveRename("Sources/NIOCore/ByteBuffer.swift")
        XCTAssertNil(previous)
        XCTAssertEqual(current, "Sources/NIOCore/ByteBuffer.swift")
    }

    func testRenameEntryCarriesBothNames() {
        let output = header("aaa", "Ann", "2024-01-01T00:00:00Z", "Move it")
                   + "\n2\t1\tSources/{NIO => NIOPosix}/SocketChannel.swift"
        let entry = FileHistoryParser.parse(output, fallbackPath: "x").first
        XCTAssertEqual(entry?.isRename, true)
        XCTAssertEqual(entry?.previousPath, "Sources/NIO/SocketChannel.swift")
        XCTAssertEqual(entry?.path, "Sources/NIOPosix/SocketChannel.swift")
    }

    func testBinaryFile() {
        let output = header("bbb", "Ann", "2024-01-01T00:00:00Z", "Update image") + "\n-\t-\tdocs/logo.png"
        let entry = FileHistoryParser.parse(output, fallbackPath: "docs/logo.png").first
        XCTAssertEqual(entry?.isBinary, true)
        XCTAssertEqual(entry?.insertions, 0, "a dash is not a count")
    }

    /// A merge commit touching the file contributes no numstat of its own.
    func testCommitWithoutANumstatStillAppears() {
        let output = [
            header("aaa", "Ann", "2024-01-02T00:00:00Z", "A merge"),
            header("bbb", "Bob", "2024-01-01T00:00:00Z", "Real change"),
            "3\t1\ta.swift",
        ].joined(separator: "\n")
        let entries = FileHistoryParser.parse(output, fallbackPath: "a.swift")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].insertions, 0)
        XCTAssertEqual(entries[0].path, "a.swift", "falls back to the path asked about")
        XCTAssertEqual(entries[1].insertions, 3)
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(FileHistoryParser.parse("", fallbackPath: "x").isEmpty)
        XCTAssertTrue(FileHistoryParser.parse("nonsense\n1\t2\tno header first", fallbackPath: "x").isEmpty)
    }

    func testCommitDetailParsesMetadataParentsBodyAndDeltas() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-commit-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try GitProcess.capture(arguments: ["init", "-q"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Alice"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "alice@example.com"], in: tempRoot)
        try "hello\n".write(to: tempRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try GitProcess.capture(arguments: ["add", "a.txt"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["commit", "-q", "-m", "Root commit"], in: tempRoot)

        let repo = GitRepository(url: tempRoot)
        let rootSHA = try repo.headSHA()
        let rootDetail = try repo.commitDetail(sha: rootSHA)
        XCTAssertTrue(rootDetail.parents.isEmpty)
        XCTAssertEqual(rootDetail.authorName, "Alice")
        XCTAssertEqual(rootDetail.authorEmail, "alice@example.com")
        XCTAssertEqual(rootDetail.subject, "Root commit")
        XCTAssertEqual(rootDetail.deltas.first?.path, "a.txt")
        XCTAssertEqual(rootDetail.deltas.first?.insertions, 1)

        try "hello\nworld\n".write(to: tempRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try GitProcess.capture(arguments: ["add", "a.txt"], in: tempRoot)
        _ = try GitProcess.capture(
            arguments: ["commit", "-q", "-m", "Second commit", "-m", "Extended explanation\nover multiple lines."],
            in: tempRoot
        )
        let secondSHA = try repo.headSHA()
        let secondDetail = try repo.commitDetail(sha: secondSHA)
        XCTAssertEqual(secondDetail.parents, [rootSHA])
        XCTAssertEqual(secondDetail.subject, "Second commit")
        XCTAssertEqual(secondDetail.body, "Extended explanation\nover multiple lines.")
        XCTAssertEqual(secondDetail.deltas.first?.insertions, 1)
    }

    func testCommitDetailParserSupportsSignatureFieldsAndLegacy9FieldOutput() {
        let signedHeader = [
            "deadbeef1234",
            "Alice",
            "alice@example.com",
            "2026-01-15T10:00:00Z",
            "Alice",
            "alice@example.com",
            "2026-01-15T10:00:00Z",
            "parent001",
            "Verified commit",
            "G",
            "Alice <alice@example.com>",
            "ABCD1234EF567890",
        ].joined(separator: "\u{1F}") + "\u{1E}Signed body"

        let signedDetail = CommitDetailParser.parse(signedHeader, deltas: [])
        XCTAssertEqual(signedDetail?.signature?.status, .good)
        XCTAssertEqual(signedDetail?.signature?.signer, "Alice <alice@example.com>")
        XCTAssertEqual(signedDetail?.signature?.key, "ABCD1234EF567890")
        XCTAssertEqual(signedDetail?.body, "Signed body")

        let legacyHeader = [
            "cafebabe5678",
            "Bob",
            "bob@example.com",
            "2026-01-15T11:00:00Z",
            "Bob",
            "bob@example.com",
            "2026-01-15T11:00:00Z",
            "",
            "Legacy commit",
        ].joined(separator: "\u{1F}") + "\u{1E}"

        let legacyDetail = CommitDetailParser.parse(legacyHeader, deltas: [])
        XCTAssertEqual(legacyDetail?.subject, "Legacy commit")
        XCTAssertNil(legacyDetail?.signature)
    }
}
