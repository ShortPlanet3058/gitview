import XCTest
@testable import GitViewGit

final class GitHubBridgeTests: XCTestCase {
    func testParsesPullRequestsAndStatusRollups() {
        let json = """
        [
          {
            "number": 42,
            "title": "Improve UI polish",
            "url": "https://github.com/ShortPlanet3058/gitview/pull/42",
            "headRefName": "feat/polish",
            "baseRefName": "main",
            "isDraft": false,
            "reviewDecision": "APPROVED",
            "author": { "login": "ShortPlanet3058" },
            "updatedAt": "2026-11-20T12:30:00Z",
            "additions": 120,
            "deletions": 15,
            "changedFiles": 4,
            "statusCheckRollup": [
              { "status": "COMPLETED", "conclusion": "SUCCESS" },
              { "state": "SUCCESS" }
            ]
          },
          {
            "number": 43,
            "title": "Failing check PR",
            "url": "https://github.com/ShortPlanet3058/gitview/pull/43",
            "headRefName": "fix/broken",
            "baseRefName": "main",
            "isDraft": true,
            "reviewDecision": null,
            "statusCheckRollup": [
              { "status": "COMPLETED", "conclusion": "SUCCESS" },
              { "status": "COMPLETED", "conclusion": "FAILURE" }
            ]
          },
          {
            "number": 44,
            "title": "Running check PR",
            "url": "https://github.com/ShortPlanet3058/gitview/pull/44",
            "headRefName": "feat/pending",
            "baseRefName": "main",
            "isDraft": false,
            "reviewDecision": "",
            "statusCheckRollup": [
              { "status": "IN_PROGRESS", "conclusion": null }
            ]
          }
        ]
        """.data(using: .utf8)!

        let prs = GitHubBridge.parsePullRequests(json: json)
        XCTAssertEqual(prs.count, 3)
        XCTAssertEqual(prs[0].number, 42)
        XCTAssertEqual(prs[0].checkStatus, .passing)
        XCTAssertEqual(prs[0].reviewDecision, "APPROVED")
        XCTAssertEqual(prs[0].authorLogin, "ShortPlanet3058")
        XCTAssertNotNil(prs[0].updatedAt)
        XCTAssertEqual(prs[0].additions, 120)
        XCTAssertEqual(prs[0].deletions, 15)
        XCTAssertEqual(prs[0].changedFiles, 4)

        XCTAssertEqual(prs[1].number, 43)
        XCTAssertNil(prs[1].authorLogin)
        XCTAssertNil(prs[1].additions)
        XCTAssertTrue(prs[1].isDraft)
        XCTAssertEqual(prs[1].checkStatus, .failing)

        XCTAssertEqual(prs[2].number, 44)
        XCTAssertEqual(prs[2].checkStatus, .pending)
    }

    func testCreatePRURLSupportsGitHubAndGitLab() {
        let gh = URL(string: "https://github.com/ShortPlanet3058/gitview")!
        XCTAssertEqual(
            GitHubBridge.createPRURL(remoteWebURL: gh, branch: "feat/foo", defaultBranch: "main")?.absoluteString,
            "https://github.com/ShortPlanet3058/gitview/compare/main...feat/foo?expand=1"
        )
        XCTAssertNil(GitHubBridge.createPRURL(remoteWebURL: gh, branch: "main", defaultBranch: "main"))

        let gl = URL(string: "https://gitlab.com/org/project")!
        let glURL = GitHubBridge.createPRURL(remoteWebURL: gl, branch: "feat/bar", defaultBranch: "main")
        XCTAssertTrue(glURL?.absoluteString.contains("/-/merge_requests/new") == true)
        XCTAssertTrue(glURL?.absoluteString.contains("feat/bar") == true)
    }

    func testLinePermalinkURLBuildsBlobFragment() {
        let gh = URL(string: "https://github.com/ShortPlanet3058/gitview")!
        let url = GitHubBridge.linePermalinkURL(
            remoteWebURL: gh,
            sha: "abc123456789",
            path: "Sources/GitView/AppShell.swift",
            line: 77
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://github.com/ShortPlanet3058/gitview/blob/abc123456789/Sources/GitView/AppShell.swift#L77"
        )
    }
}
