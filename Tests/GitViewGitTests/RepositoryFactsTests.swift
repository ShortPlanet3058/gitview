import XCTest
@testable import GitViewGit
import GitViewCore

final class RepositoryFactsTests: XCTestCase {
    func testRemoteToWebURL() {
        XCTAssertEqual(GitRepository.webURL(fromRemote: "git@github.com:apple/swift-nio.git")?.absoluteString,
                       "https://github.com/apple/swift-nio")
        XCTAssertEqual(GitRepository.webURL(fromRemote: "https://github.com/apple/swift-nio.git")?.absoluteString,
                       "https://github.com/apple/swift-nio")
        XCTAssertEqual(GitRepository.webURL(fromRemote: "ssh://git@gitlab.com/group/proj.git")?.absoluteString,
                       "https://gitlab.com/group/proj")
        XCTAssertNil(GitRepository.webURL(fromRemote: "/Users/me/local-mirror"))
    }

    func testReadmeFirstParagraphSkipsHeadingsBadgesAndLists() {
        let readme = """
        # SwiftNIO
        [![Build](https://x/badge.svg)](https://x)

        SwiftNIO is a cross-platform asynchronous event-driven network application framework
        for rapid development of maintainable high performance protocol servers & clients.

        ## Repository organization
        - one
        """
        XCTAssertEqual(GitRepository.firstParagraph(ofMarkdown: readme),
                       "SwiftNIO is a cross-platform asynchronous event-driven network application framework "
                       + "for rapid development of maintainable high performance protocol servers & clients.")
    }

    func testReadmeLinksAndEmphasisAreFlattenedAndLongTextTruncated() {
        let readme = "Use **GitView** with [git](https://git-scm.com) today. " + String(repeating: "x", count: 400)
        let summary = GitRepository.firstParagraph(ofMarkdown: readme)!
        XCTAssertTrue(summary.hasPrefix("Use GitView with git today."))
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertLessThanOrEqual(summary.count, 280)
    }

    func testFileCategories() {
        XCTAssertEqual(FileInventory.category(forExtension: "swift"), "Source code")
        XCTAssertEqual(FileInventory.category(forExtension: "PNG"), "Assets")
        XCTAssertEqual(FileInventory.category(forExtension: "md"), "Documents")
        XCTAssertEqual(FileInventory.category(forExtension: "xyz"), "Other")
    }

    func testParseConfigListExtractsRemotesAndIdentities() {
        let config = """
        user.name=Global Alice
        user.email=Alice@Example.com
        remote.origin.url=git@github.com:fork/gitview.git
        remote.upstream.url=https://github.com/org/gitview.git
        user.name=Work Alice
        """
        let summary = GitRepository.parseConfigList(config)
        XCTAssertEqual(summary.userNames, ["Global Alice", "Work Alice"])
        XCTAssertEqual(summary.userEmails, ["alice@example.com"])
        XCTAssertEqual(summary.remotes["origin"], "git@github.com:fork/gitview.git")
        XCTAssertEqual(summary.remotes["upstream"], "https://github.com/org/gitview.git")
    }

    func testParseWorktreesIdentifiesCurrentAndBranches() {
        let output = """
        worktree /tmp/repo-main
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /tmp/repo-feature
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feat/x

        worktree /tmp/repo-detached
        HEAD 3333333333333333333333333333333333333333
        detached
        """
        let trees = GitRepository.parseWorktrees(output, currentRoot: URL(fileURLWithPath: "/tmp/repo-feature"))
        XCTAssertEqual(trees.count, 3)
        XCTAssertFalse(trees[0].isCurrent)
        XCTAssertEqual(trees[0].branch, "main")
        XCTAssertTrue(trees[1].isCurrent)
        XCTAssertEqual(trees[1].branch, "feat/x")
        XCTAssertNil(trees[2].branch)
    }

    func testParseBranchRowsKeepsUpstreamAndDeduplicatesOrigin() {
        let output = [
            "refs/remotes/origin/main\u{1F}sha1\u{1F}2025-03-01T10:00:00Z\u{1F}Alice\u{1F}Newer origin",
            "refs/remotes/upstream/main\u{1F}shaU\u{1F}2025-02-20T10:00:00Z\u{1F}Maintainer\u{1F}Upstream",
            "refs/remotes/origin/remote-only\u{1F}shaR\u{1F}2025-02-15T10:00:00Z\u{1F}Bob\u{1F}Remote only",
            "refs/heads/main\u{1F}shaLocal\u{1F}2025-02-10T10:00:00Z\u{1F}Alice\u{1F}Local main",
            "refs/remotes/origin/HEAD\u{1F}sha1\u{1F}2025-03-01T10:00:00Z\u{1F}Alice\u{1F}HEAD pointer",
        ].joined(separator: "\n")

        let rows = GitRepository.parseBranchRows(output)
        XCTAssertEqual(rows.map(\.name), ["upstream/main", "remote-only", "main"])
        XCTAssertEqual(rows[0].remoteName, "upstream")
        XCTAssertEqual(rows[1].remoteName, "origin")
        XCTAssertFalse(rows[2].isRemote)
    }

    func testCachedDivergenceReusedInRepositoryBranches() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-facts-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try GitProcess.capture(arguments: ["init", "-b", "main", "-q"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Alice"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "alice@example.com"], in: tempRoot)
        try "1\n".write(to: tempRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try GitProcess.capture(arguments: ["add", "a.txt"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["commit", "-q", "-m", "Root"], in: tempRoot)

        let repo = GitRepository(url: tempRoot)
        let mainSHA = try repo.headSHA()
        try repo.createBranch(name: "feat", checkout: true)
        try "2\n".write(to: tempRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try repo.stage(paths: ["a.txt"])
        let featSHA = try repo.commit(subject: "Feat commit")

        let first = try repo.branches(defaultBranch: "main", currentBranch: "feat", cachedDivergence: [:])
        let pair = AnalysisCache.DivergencePair(baseSHA: mainSHA, tipSHA: featSHA)
        XCTAssertEqual(first.computedDivergence[pair]?.ahead, 1)
        XCTAssertEqual(first.computedDivergence[pair]?.behind, 0)

        let second = try repo.branches(defaultBranch: "main", currentBranch: "feat",
                                       cachedDivergence: first.computedDivergence)
        XCTAssertTrue(second.computedDivergence.isEmpty, "Cache hit should skip rev-list computation")
        let featInfo = try XCTUnwrap(second.branches.first { $0.name == "feat" })
        XCTAssertEqual(featInfo.ahead, 1)
        XCTAssertEqual(featInfo.behind, 0)
    }

    func testValidateFromSubdirectoryAndPosixInventory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitview-facts-lstat-\(UUID().uuidString)")
        let nestedDir = tempRoot.appendingPathComponent("Sources/Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try GitProcess.capture(arguments: ["init", "-b", "main", "-q"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.name", "Alice"], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["config", "user.email", "alice@example.com"], in: tempRoot)
        let sourceURL = nestedDir.appendingPathComponent("App.swift")
        let content = "func greet() { print(\"hi\") }\n"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        try "*.tmp\n".write(to: tempRoot.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try GitProcess.capture(arguments: ["add", "."], in: tempRoot)
        _ = try GitProcess.capture(arguments: ["commit", "-q", "-m", "Add source"], in: tempRoot)

        let validatedFromSub = try GitRepository(url: nestedDir).validate()
        XCTAssertEqual(validatedFromSub.resolvingSymlinksInPath().standardizedFileURL.path,
                       tempRoot.resolvingSymlinksInPath().standardizedFileURL.path)

        let inv = GitRepository.inventory(in: validatedFromSub)
        XCTAssertEqual(inv.fileCount, 2)
        let swiftEntry = try XCTUnwrap(inv.files.first { $0.path == "Sources/Sub/App.swift" })
        XCTAssertEqual(swiftEntry.bytes, Int64(content.utf8.count))
        XCTAssertNotNil(swiftEntry.modified)
        XCTAssertEqual(inv.bytesByCategory["Source code"], Int64(content.utf8.count))

        // Non-repo directory throws GitError.notARepository.
        let nonRepo = FileManager.default.temporaryDirectory.appendingPathComponent("gitview-nonrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepo) }
        XCTAssertThrowsError(try GitRepository(url: nonRepo).validate())
    }
}
