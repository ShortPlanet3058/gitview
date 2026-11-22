import XCTest
@testable import GitViewCore

private func makeUnit(_ name: String, _ range: ClosedRange<Int>, path: String = "A.swift") -> CodeUnit {
    CodeUnit(filePath: path, name: name, kind: .function, lineRange: range,
             complexity: 1, nestingDepth: 0, lineCount: range.count)
}

private func makeCommit(
    _ sha: String,
    _ day: Int,
    author: String = "dev",
    _ changes: [FileChange]
) -> Commit {
    Commit(sha: sha, author: author,
           date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
           fileChanges: changes)
}

final class ChurnJoinerTests: XCTestCase {

    func testHunkArithmeticEndToEnd() {
        // newStart 14, count 5 covers 14...18 — it must NOT reach line 19.
        let inRange = makeUnit("inRange", 18...30)
        let outOfRange = makeUnit("outOfRange", 19...30)
        let commits = [makeCommit("a", 1, [
            FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 14, newLineCount: 5)])
        ])]

        let index = ChurnJoiner.join(units: [inRange, outOfRange], commits: commits)
        XCTAssertEqual(index.commitCount(for: inRange), 1)
        XCTAssertEqual(index.commitCount(for: outOfRange), 0)
    }

    func testPureDeletionIsAttributedToTheSurroundingUnit() {
        // "+41,0" removes lines and adds none. It is still churn for the unit it sits in.
        let unit = makeUnit("f", 30...50)
        let commits = [makeCommit("a", 1, [
            FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 41, newLineCount: 0)])
        ])]
        XCTAssertEqual(ChurnJoiner.join(units: [unit], commits: commits).commitCount(for: unit), 1)
    }

    func testCommitTouchingUnitViaSeveralHunksCountsOnce() {
        let unit = makeUnit("f", 1...100)
        let commits = [makeCommit("a", 1, [
            FileChange(path: "A.swift", oldPath: nil, hunks: [
                Hunk(newStart: 10, newLineCount: 2),
                Hunk(newStart: 40, newLineCount: 2),
                Hunk(newStart: 80, newLineCount: 2),
            ])
        ])]
        XCTAssertEqual(ChurnJoiner.join(units: [unit], commits: commits).commitCount(for: unit), 1)
    }

    func testCommitTouchingUnitViaSeveralFilesCountsOnce() {
        // Same commit, same unit reachable through a rename alias and the current path.
        let unit = makeUnit("f", 1...100)
        let commits = [makeCommit("a", 1, [
            FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 10, newLineCount: 1)]),
            FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 20, newLineCount: 1)]),
        ])]
        XCTAssertEqual(ChurnJoiner.join(units: [unit], commits: commits).commitCount(for: unit), 1)
    }

    func testDistinctCommitsAccumulate() {
        let unit = makeUnit("f", 1...100)
        let commits = [
            makeCommit("c", 3, author: "ann", [FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
            makeCommit("b", 2, author: "bob", [FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
            makeCommit("a", 1, author: "ann", [FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
        ]
        let index = ChurnJoiner.join(units: [unit], commits: commits)
        XCTAssertEqual(index.commitCount(for: unit), 3)
        XCTAssertEqual(index.authors(for: unit), ["ann", "bob"])
        XCTAssertEqual(index.lastTouched(for: unit), Date(timeIntervalSince1970: 3 * 86_400))
    }

    // MARK: - Renames

    func testSingleRenameAttributesOlderCommitsToCurrentPath() {
        // Units come from the checkout (New.swift). History before the rename says Old.swift.
        let unit = makeUnit("f", 1...100, path: "New.swift")
        let commits = [
            // newest first, as git log emits
            makeCommit("rename", 2, [
                FileChange(path: "New.swift", oldPath: "Old.swift", hunks: [Hunk(newStart: 5, newLineCount: 1)])
            ]),
            makeCommit("before", 1, [
                FileChange(path: "Old.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])
            ]),
        ]
        XCTAssertEqual(ChurnJoiner.join(units: [unit], commits: commits).commitCount(for: unit), 2)
    }

    func testRenameChainComposes() {
        // A -> B -> C. A commit touching A must still reach the unit now living in C.swift.
        let unit = makeUnit("f", 1...100, path: "C.swift")
        let commits = [
            makeCommit("bToC", 3, [FileChange(path: "C.swift", oldPath: "B.swift", hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
            makeCommit("aToB", 2, [FileChange(path: "B.swift", oldPath: "A.swift", hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
            makeCommit("original", 1, [FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
        ]
        XCTAssertEqual(ChurnJoiner.join(units: [unit], commits: commits).commitCount(for: unit), 3)
    }

    func testPathReusedAfterRenameIsNotConfused() {
        // Old.swift is renamed away, then a *new* file takes the same name. Commits to the
        // new file must not be credited to the renamed-away unit.
        let moved = makeUnit("moved", 1...100, path: "New.swift")
        let fresh = makeUnit("fresh", 1...100, path: "Old.swift")
        let commits = [
            makeCommit("touchFresh", 3, [FileChange(path: "Old.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
            makeCommit("rename", 2, [FileChange(path: "New.swift", oldPath: "Old.swift", hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
            makeCommit("original", 1, [FileChange(path: "Old.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
        ]
        let index = ChurnJoiner.join(units: [moved, fresh], commits: commits)
        // "touchFresh" is newer than the rename, so it belongs to the new Old.swift.
        XCTAssertEqual(index.commitCount(for: fresh), 1)
        // "rename" and "original" belong to the unit that moved to New.swift.
        XCTAssertEqual(index.commitCount(for: moved), 2)
    }

    // MARK: - Accounting

    func testHunksOutsideAnyUnitAreCountedNotDropped() {
        // Imports and blank lines legitimately fall outside every unit. The count is how
        // we detect line drift getting out of hand.
        let unit = makeUnit("f", 50...60)
        let commits = [makeCommit("a", 1, [
            FileChange(path: "A.swift", oldPath: nil, hunks: [
                Hunk(newStart: 1, newLineCount: 1),   // an import, say
                Hunk(newStart: 55, newLineCount: 1),  // inside the unit
            ])
        ])]
        let index = ChurnJoiner.join(units: [unit], commits: commits)
        XCTAssertEqual(index.matchedHunks, 1)
        XCTAssertEqual(index.unmatchedHunks, 1)
    }

    func testChangesToUnparsedFilesAreCountedSeparately() {
        let unit = makeUnit("f", 1...10)
        let commits = [makeCommit("a", 1, [
            FileChange(path: "README.md", oldPath: nil, hunks: [Hunk(newStart: 1, newLineCount: 3)])
        ])]
        let index = ChurnJoiner.join(units: [unit], commits: commits)
        XCTAssertEqual(index.unresolvedPaths, 1)
        XCTAssertEqual(index.matchedHunks, 0)
    }

    func testMergeCommitWithNoChangesIsHarmless() {
        let unit = makeUnit("f", 1...10)
        let commits = [makeCommit("merge", 2, []),
                       makeCommit("real", 1, [FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])])]
        XCTAssertEqual(ChurnJoiner.join(units: [unit], commits: commits).commitCount(for: unit), 1)
    }

    func testNestedUnitsBothReceiveTheCommit() {
        let type = makeUnit("Type", 1...100)
        let method = makeUnit("method", 40...50)
        let commits = [makeCommit("a", 1, [
            FileChange(path: "A.swift", oldPath: nil, hunks: [Hunk(newStart: 45, newLineCount: 1)])
        ])]
        let index = ChurnJoiner.join(units: [type, method], commits: commits)
        XCTAssertEqual(index.commitCount(for: type), 1)
        XCTAssertEqual(index.commitCount(for: method), 1)
    }

    func testPureRenameWithNoHunksStillBridgesOlderHistory() {
        let unit = makeUnit("f", 1...100, path: "New.swift")
        let commits = [
            makeCommit("pureMove", 2, [FileChange(path: "New.swift", oldPath: "Old.swift", hunks: [])]),
            makeCommit("before", 1, [FileChange(path: "Old.swift", oldPath: nil, hunks: [Hunk(newStart: 5, newLineCount: 1)])]),
        ]
        XCTAssertEqual(ChurnJoiner.join(units: [unit], commits: commits).commitCount(for: unit), 1)
    }

    func testTopInsertionShiftsUnitRangeBackwardAcrossOlderCommits() {
        // Head state: f spans 50...60. Commit 2 inserted 40 lines near the top (lines 5...44);
        // commit 1 edited old lines 12...14 (which became HEAD lines 52...54).
        let unit = makeUnit("f", 50...60)
        let commits = [
            makeCommit("insertTop", 2, [
                FileChange(path: "A.swift", hunks: [Hunk(oldStart: 4, oldLineCount: 0, newStart: 5, newLineCount: 40)])
            ]),
            makeCommit("editOld", 1, [
                FileChange(path: "A.swift", hunks: [Hunk(oldStart: 12, oldLineCount: 2, newStart: 12, newLineCount: 3)])
            ]),
        ]
        let index = ChurnJoiner.join(units: [unit], commits: commits)
        XCTAssertEqual(index.commitCount(for: unit), 1)
        XCTAssertEqual(index.commits(for: unit).map(\.sha), ["editOld"])
    }

    func testPureDeletionShiftsUnitRangeBackwardAcrossOlderCommits() {
        // Commit 2 deleted 10 lines before the unit (old lines 5...14, @@ -5,10 +4,0 @@).
        // So HEAD unit 10...20 lived at old lines 20...30 when commit 1 edited line 25.
        let unit = makeUnit("f", 10...20)
        let commits = [
            makeCommit("deleteAbove", 2, [
                FileChange(path: "A.swift", hunks: [Hunk(oldStart: 5, oldLineCount: 10, newStart: 4, newLineCount: 0)])
            ]),
            makeCommit("editOld", 1, [
                FileChange(path: "A.swift", hunks: [Hunk(oldStart: 25, oldLineCount: 1, newStart: 25, newLineCount: 1)])
            ]),
        ]
        let index = ChurnJoiner.join(units: [unit], commits: commits)
        XCTAssertEqual(index.commits(for: unit).map(\.sha), ["editOld"])
    }

    func testUnitBornInPureInsertionOrNewFileRetiresBeforeOlderCommits() {
        let bornInHunk = makeUnit("bornInHunk", 20...30, path: "A.swift")
        let bornInNewFile = makeUnit("bornInNewFile", 1...15, path: "B.swift")
        let commits = [
            makeCommit("createBoth", 2, [
                FileChange(path: "A.swift", hunks: [Hunk(oldStart: 10, oldLineCount: 0, newStart: 15, newLineCount: 20)]),
                FileChange(path: "B.swift", hunks: [Hunk(oldStart: 0, oldLineCount: 0, newStart: 1, newLineCount: 20)], isNewFile: true),
            ]),
            makeCommit("unrelatedOld", 1, [
                FileChange(path: "A.swift", hunks: [Hunk(oldStart: 22, oldLineCount: 1, newStart: 22, newLineCount: 1)]),
                FileChange(path: "B.swift", hunks: [Hunk(oldStart: 5, oldLineCount: 1, newStart: 5, newLineCount: 1)]),
            ]),
        ]
        let index = ChurnJoiner.join(units: [bornInHunk, bornInNewFile], commits: commits)
        XCTAssertEqual(index.commits(for: bornInHunk).map(\.sha), ["createBoth"])
        XCTAssertEqual(index.commits(for: bornInNewFile).map(\.sha), ["createBoth"])
    }

    func testEmptyInputs() {
        XCTAssertEqual(ChurnJoiner.join(units: [], commits: []).touchesByUnit.count, 0)
        let unit = makeUnit("f", 1...10)
        XCTAssertEqual(ChurnJoiner.join(units: [unit], commits: []).commitCount(for: unit), 0)
    }
}
