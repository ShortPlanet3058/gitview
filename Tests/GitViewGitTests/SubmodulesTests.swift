import XCTest
@testable import GitViewGit

final class SubmodulesTests: XCTestCase {
    func testParsesAllGitSubmoduleStatusPrefixes() {
        let output = """
         9a1b2c3d4e5f Vendor/CleanLib (v1.2.0)
        -0f1e2d3c4b5a Vendor/Uninitialized
        +abcdef123456 Vendor/Modified Sub (heads/main)
        Ufedcba654321 Vendor/ConflictedLib
        """

        let parsed = SubmoduleParser.parse(output)
        XCTAssertEqual(parsed.count, 4)

        XCTAssertEqual(parsed[0].path, "Vendor/CleanLib")
        XCTAssertEqual(parsed[0].sha, "9a1b2c3d4e5f")
        XCTAssertEqual(parsed[0].describe, "v1.2.0")
        XCTAssertEqual(parsed[0].state, .clean)

        XCTAssertEqual(parsed[1].path, "Vendor/Uninitialized")
        XCTAssertNil(parsed[1].describe)
        XCTAssertEqual(parsed[1].state, .uninitialized)

        XCTAssertEqual(parsed[2].path, "Vendor/Modified Sub")
        XCTAssertEqual(parsed[2].describe, "heads/main")
        XCTAssertEqual(parsed[2].state, .modified)

        XCTAssertEqual(parsed[3].path, "Vendor/ConflictedLib")
        XCTAssertEqual(parsed[3].state, .mergeConflict)
    }
}
