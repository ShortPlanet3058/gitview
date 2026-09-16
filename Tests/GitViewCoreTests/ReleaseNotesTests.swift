import XCTest
@testable import GitViewCore

private func commit(_ sha: String, _ subject: String, author: String = "Ann") -> Commit {
    Commit(sha: sha, author: author, date: Date(timeIntervalSince1970: 1_700_000_000),
           subject: subject, fileChanges: [])
}

final class ReleaseNotesTests: XCTestCase {

    func testConventionalCommitsAreGrouped() {
        XCTAssertEqual(ReleaseNotes.heading(for: "feat: add sockets"), "Features")
        XCTAssertEqual(ReleaseNotes.heading(for: "fix(http): handle empty body"), "Fixes")
        XCTAssertEqual(ReleaseNotes.heading(for: "feat!: breaking change"), "Features")
        XCTAssertEqual(ReleaseNotes.heading(for: "docs: Document ByteBuffer"), "Documentation")
        XCTAssertEqual(ReleaseNotes.heading(for: "chore: tidy"), "Chores")
    }

    /// Most repositories have never heard of the convention; their subjects still start with
    /// a verb, which is enough to group by.
    func testLeadingVerbsAreGroupedForProjectsWithoutAConvention() {
        XCTAssertEqual(ReleaseNotes.heading(for: "Add socket option API for SO_REUSEPORT (#3741)"), "Added")
        XCTAssertEqual(ReleaseNotes.heading(for: "Fix the Returns callout (#3740)"), "Fixed")
        XCTAssertEqual(ReleaseNotes.heading(for: "Fixed a leak"), "Fixed")
        XCTAssertEqual(ReleaseNotes.heading(for: "Bump actions/checkout from 6.0.1 to 6.0.2"), "Updated")
        XCTAssertEqual(ReleaseNotes.heading(for: "Removes dead code"), "Removed")
        XCTAssertEqual(ReleaseNotes.heading(for: "Speed up branch loading"), "Improved")
    }

    func testUnrecognisedSubjectsFallThroughRatherThanBeingDropped() {
        XCTAssertNil(ReleaseNotes.heading(for: "SwiftNIO 2.1 release preparation"))
        let sections = ReleaseNotes.sections(for: [commit("a", "SwiftNIO 2.1 release preparation")])
        XCTAssertEqual(sections.map(\.title), ["Other changes"])
    }

    /// A colon in prose must not be mistaken for a conventional-commit type.
    func testProseColonIsNotATypePrefix() {
        XCTAssertEqual(ReleaseNotes.heading(for: "Add support for HTTP: the sequel"), "Added")
        XCTAssertNil(ReleaseNotes.heading(for: "NIOHTTP1: tidy up"))
    }

    func testMergeCommitsAreLeftOut() {
        XCTAssertTrue(ReleaseNotes.isNoise(commit("a", "Merge pull request #3741 from x/y")))
        XCTAssertFalse(ReleaseNotes.isNoise(commit("b", "Merged tokens into one type")))
        let sections = ReleaseNotes.sections(for: [
            commit("a", "Merge pull request #1 from x/y"),
            commit("b", "Fix a crash"),
        ])
        XCTAssertEqual(sections.flatMap { $0.entries }.map(\.sha), ["b"])
    }

    func testSectionsAppearInAStableOrder() {
        let sections = ReleaseNotes.sections(for: [
            commit("a", "chore: tidy"),
            commit("b", "Something unclassifiable"),
            commit("c", "feat: add a thing"),
            commit("d", "fix: repair a thing"),
        ])
        XCTAssertEqual(sections.map(\.title), ["Features", "Fixes", "Chores", "Other changes"])
    }

    func testMarkdownIsPasteable() {
        let notes = ReleaseNotes.markdown(title: "2.102.0", commits: [
            commit("aaaaaaa1", "Add socket option API", author: "Si Beaumont"),
            commit("bbbbbbb2", "Fix a crash", author: "Ann"),
            commit("ccccccc3", "Merge pull request #1", author: "Ann"),
        ])
        XCTAssertTrue(notes.hasPrefix("## 2.102.0"))
        XCTAssertTrue(notes.contains("### Added"))
        XCTAssertTrue(notes.contains("- Add socket option API (`aaaaaaa`)"))
        XCTAssertTrue(notes.contains("### Fixed"))
        XCTAssertTrue(notes.contains("@Ann, @Si Beaumont"))
        XCTAssertTrue(notes.contains("_2 commits by 2 people._"), "the merge is not counted")
        XCTAssertFalse(notes.contains("Merge pull request"))
    }

    func testEmptyRange() {
        let notes = ReleaseNotes.markdown(title: "2.0.0", commits: [])
        XCTAssertTrue(notes.contains("_No changes._"))
        XCTAssertTrue(ReleaseNotes.sections(for: []).isEmpty)
    }
}
