import XCTest
@testable import GitViewCore

final class CommitGraphLayoutTests: XCTestCase {

    private func makeCommit(_ sha: String, parents: [String]) -> Commit {
        Commit(sha: sha, parents: parents, author: "Ann", date: Date(), subject: sha, fileChanges: [])
    }

    func testLinearHistoryStaysOnSingleLane() {
        let commits = [
            makeCommit("c3", parents: ["c2"]),
            makeCommit("c2", parents: ["c1"]),
            makeCommit("c1", parents: []),
        ]
        let rows = CommitGraphLayout.build(commits: commits)
        XCTAssertEqual(rows.count, 3)

        XCTAssertEqual(rows["c3"]?.nodeLane, 0)
        XCTAssertEqual(rows["c3"]?.upperSegments, [])
        XCTAssertEqual(rows["c3"]?.lowerSegments, [.init(fromLane: 0, toLane: 0, colorIndex: 0)])

        XCTAssertEqual(rows["c2"]?.nodeLane, 0)
        XCTAssertEqual(rows["c2"]?.upperSegments, [.init(fromLane: 0, toLane: 0, colorIndex: 0)])
        XCTAssertEqual(rows["c2"]?.lowerSegments, [.init(fromLane: 0, toLane: 0, colorIndex: 0)])

        XCTAssertEqual(rows["c1"]?.nodeLane, 0)
        XCTAssertTrue(rows["c1"]?.lowerSegments.isEmpty ?? false)
    }

    func testMergeForkAndRejoinAssignsSecondLaneAndRejoinsCleanly() {
        let commits = [
            makeCommit("merge", parents: ["main2", "feat1"]),
            makeCommit("feat1", parents: ["base"]),
            makeCommit("main2", parents: ["base"]),
            makeCommit("base", parents: []),
        ]
        let rows = CommitGraphLayout.build(commits: commits)

        let mergeRow = rows["merge"]
        XCTAssertEqual(mergeRow?.nodeLane, 0)
        XCTAssertEqual(mergeRow?.isMerge, true)
        XCTAssertEqual(mergeRow?.laneCount, 2)
        XCTAssertTrue(mergeRow?.lowerSegments.contains(.init(fromLane: 0, toLane: 0, colorIndex: 0)) ?? false)
        XCTAssertTrue(mergeRow?.lowerSegments.contains(.init(fromLane: 0, toLane: 1, colorIndex: 1)) ?? false)

        let featRow = rows["feat1"]
        XCTAssertEqual(featRow?.nodeLane, 1)
        // Wait target for main2 passes straight through lane 0, while feat1 connects 1 -> 1 (expecting base)
        XCTAssertTrue(featRow?.upperSegments.contains(.init(fromLane: 0, toLane: 0, colorIndex: 0)) ?? false)
        XCTAssertTrue(featRow?.lowerSegments.contains(.init(fromLane: 0, toLane: 0, colorIndex: 0)) ?? false)
        XCTAssertTrue(featRow?.lowerSegments.contains(.init(fromLane: 1, toLane: 1, colorIndex: 1)) ?? false)

        let main2Row = rows["main2"]
        XCTAssertEqual(main2Row?.nodeLane, 0)
        // main2 shares parent base which already lives in lane 1 -> redirects 0 -> 1
        XCTAssertTrue(main2Row?.lowerSegments.contains(.init(fromLane: 0, toLane: 1, colorIndex: 0)) ?? false)

        let baseRow = rows["base"]
        XCTAssertEqual(baseRow?.nodeLane, 1)
    }

    func testRespectsMaxLanesCapOnWideBranchFanOut() {
        let commits = [
            makeCommit("octopus", parents: ["p1", "p2", "p3", "p4", "p5"]),
            makeCommit("p1", parents: []),
            makeCommit("p2", parents: []),
            makeCommit("p3", parents: []),
            makeCommit("p4", parents: []),
            makeCommit("p5", parents: []),
        ]
        let rows = CommitGraphLayout.build(commits: commits, maxLanes: 3)
        for row in rows.values {
            XCTAssertLessThan(row.nodeLane, 3)
            for seg in row.upperSegments + row.lowerSegments {
                XCTAssertLessThan(seg.fromLane, 3)
                XCTAssertLessThan(seg.toLane, 3)
            }
        }
    }
}
