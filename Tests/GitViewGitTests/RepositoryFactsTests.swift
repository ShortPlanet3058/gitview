import XCTest
@testable import GitViewGit

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
}
