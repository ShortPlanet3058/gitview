import XCTest
@testable import GitViewCore

final class PathClassifierTests: XCTestCase {
    func testRecognisesTestPaths() {
        for path in [
            "Tests/GitViewCoreTests/RiskModelTests.swift",
            "Tests/Foo.swift",
            "Sources/App/MyFeatureTests/Helper.swift",
            "Sources/App/ThingTest.swift",
            "Sources/App/TestHelpers.swift",
            "Sources/App/NetworkMock.swift",
        ] {
            XCTAssertTrue(PathClassifier.isTest(path: path), path)
        }
    }

    func testDoesNotFlagProductionCode() {
        for path in [
            "Sources/GitViewCore/RiskModel.swift",
            "Sources/NIOPosix/SocketChannel.swift",
            "Sources/App/Contest.swift",     // ends in "test" but not "Test"
            "Sources/Latest/Thing.swift",    // directory merely contains "test"
        ] {
            XCTAssertFalse(PathClassifier.isTest(path: path), path)
        }
    }
}
