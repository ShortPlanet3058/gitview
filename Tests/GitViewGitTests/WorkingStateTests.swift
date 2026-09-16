import XCTest
@testable import GitViewGit

final class WorkingStateParserTests: XCTestCase {

    /// Real `git status --porcelain=v2 --branch -z` output, captured from a repository put
    /// into every interesting state. Hand-written fixtures hide exactly the details that
    /// break parsers — the rename's separate NUL field, and untracked directories
    /// collapsing to a single entry with a trailing slash.
    private let fixture = [
        "# branch.oid 41645717fb32c7ce4a06a291d7372bda7bb637f5",
        "# branch.head main",
        "# branch.upstream origin/main",
        "# branch.ab +2 -3",
        "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 2ce75e2a24f7d6841a504cf3616ef5a59edb3a2d added.txt",
        "1 .D N... 100644 100644 000000 2bdf67abb163a4ffb2d7f3f0880c9fe5068ce782 2bdf67abb163a4ffb2d7f3f0880c9fe5068ce782 deleted.txt",
        "1 .M N... 100644 100644 100644 5626abf0f72e58d7a153368ba57db4c673c0e171 5626abf0f72e58d7a153368ba57db4c673c0e171 kept.txt",
        "2 R. N... 100644 100644 100644 8510665149157c2bc901848c3e0b746954e9cbd9 8510665149157c2bc901848c3e0b746954e9cbd9 R100 renamed-to.txt",
        "renamed-from.txt",
        "1 MM N... 100644 100644 100644 54f9d6da5c91d556e6b54340b1327573073030af 5566e76124ed28273ec6d4dae9e61c291e034b56 staged.txt",
        "? sub/",
        "? untracked.txt",
    ].joined(separator: "\0") + "\0"

    private var state: WorkingState {
        WorkingStateParser.parse(porcelain: fixture, stashList: "", operation: nil)
    }

    func testBranchAndTracking() {
        XCTAssertEqual(state.branch, "main")
        XCTAssertEqual(state.upstream, "origin/main")
        XCTAssertEqual(state.ahead, 2)
        XCTAssertEqual(state.behind, 3)
        XCTAssertTrue(state.hasUnpushedCommits)
        XCTAssertFalse(state.isDetached)
        XCTAssertEqual(state.headSHA, "41645717fb32c7ce4a06a291d7372bda7bb637f5")
    }

    func testEveryFileStateIsClassified() {
        let byPath = Dictionary(uniqueKeysWithValues: state.files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["added.txt"]?.staged, .added)
        XCTAssertEqual(byPath["added.txt"]?.unstaged, .unchanged)
        XCTAssertEqual(byPath["deleted.txt"]?.unstaged, .deleted)
        XCTAssertEqual(byPath["kept.txt"]?.unstaged, .modified)
        // Staged *and* edited again afterwards: both halves must be reported.
        XCTAssertEqual(byPath["staged.txt"]?.staged, .modified)
        XCTAssertEqual(byPath["staged.txt"]?.unstaged, .modified)
        XCTAssertEqual(byPath["untracked.txt"]?.unstaged, .untracked)
    }

    func testRenameCarriesItsOriginalPathFromTheFollowingRecord() {
        let renamed = state.files.first { $0.path == "renamed-to.txt" }
        XCTAssertEqual(renamed?.staged, .renamed)
        XCTAssertEqual(renamed?.originalPath, "renamed-from.txt")
        // The original path must not be mistaken for a file of its own.
        XCTAssertNil(state.files.first { $0.path == "renamed-from.txt" })
    }

    func testUntrackedDirectoryIsOneEntry() {
        XCTAssertEqual(state.untracked.map(\.path).sorted(), ["sub/", "untracked.txt"])
    }

    func testGroupings() {
        XCTAssertEqual(Set(state.staged.map(\.path)), ["added.txt", "renamed-to.txt", "staged.txt"])
        XCTAssertEqual(Set(state.unstaged.map(\.path)), ["deleted.txt", "kept.txt", "staged.txt"])
        XCTAssertTrue(state.conflicted.isEmpty)
        XCTAssertFalse(state.isClean)
        XCTAssertTrue(state.hasLocalWork)
    }

    func testCleanRepository() {
        let clean = WorkingStateParser.parse(
            porcelain: "# branch.oid abc\0# branch.head main\0# branch.ab +0 -0\0",
            stashList: "", operation: nil)
        XCTAssertTrue(clean.isClean)
        XCTAssertFalse(clean.hasLocalWork)
        XCTAssertFalse(clean.hasUnpushedCommits)
    }

    func testDetachedHead() {
        let detached = WorkingStateParser.parse(
            porcelain: "# branch.oid abc\0# branch.head (detached)\0", stashList: "", operation: nil)
        XCTAssertTrue(detached.isDetached)
        XCTAssertNil(detached.branch)
    }

    func testConflicts() {
        let record = "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.txt"
        let merging = WorkingStateParser.parse(porcelain: "# branch.head main\0\(record)\0",
                                               stashList: "", operation: .merge)
        XCTAssertEqual(merging.conflicted.map(\.path), ["conflicted.txt"])
        XCTAssertEqual(merging.operation?.label, "Merge in progress")
        XCTAssertFalse(merging.isClean)
    }

    func testPathsWithSpacesSurvive() {
        let record = "1 .M N... 100644 100644 100644 aaa bbb sub/with space.txt"
        let parsed = WorkingStateParser.parse(porcelain: "\(record)\0", stashList: "", operation: nil)
        XCTAssertEqual(parsed.files.map(\.path), ["sub/with space.txt"])
    }

    func testStashes() {
        let list = "stash@{0}\u{1F}On main: wip: my stash\u{1F}1700000000\n"
                 + "stash@{1}\u{1F}WIP on main: 1234 earlier\u{1F}1699000000"
        let stashes = WorkingStateParser.parseStashes(list)
        XCTAssertEqual(stashes.count, 2)
        XCTAssertEqual(stashes[0].ref, "stash@{0}")
        XCTAssertEqual(stashes[0].message, "On main: wip: my stash")
        XCTAssertEqual(stashes[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(WorkingStateParser.parseStashes("").isEmpty)
    }

    func testStashesAloneCountAsLocalWork() {
        let state = WorkingStateParser.parse(
            porcelain: "# branch.head main\0",
            stashList: "stash@{0}\u{1F}On main: forgotten\u{1F}1700000000", operation: nil)
        XCTAssertTrue(state.isClean, "no modified files")
        XCTAssertTrue(state.hasLocalWork, "but a stash is still work only on this machine")
    }

    func testGarbageDoesNotCrash() {
        XCTAssertNoThrow(WorkingStateParser.parse(porcelain: "nonsense\0\01 bad\0", stashList: "x", operation: nil))
    }
}
