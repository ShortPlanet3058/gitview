import XCTest
@testable import GitViewParse
import GitViewCore

/// Every supported language is held to the same standard: its query must compile against
/// its own grammar, extract the expected units, and produce a complexity the test states
/// term by term. A grammar's node names are not guessable — Ruby calls a keyword and a
/// statement both `for`, TypeScript names classes with `type_identifier` where JavaScript
/// uses `identifier` — so each entry is pinned here.
final class LanguageSupportTests: XCTestCase {

    func testEveryLanguageHasASampleAndCompiles() throws {
        for support in LanguageSupport.all {
            XCTAssertNotNil(LanguageProbe.samples[support.id], "\(support.id) has no probe sample")
            XCTAssertNoThrow(try UnitExtractor(support: support), "\(support.id) query does not compile")
        }
    }

    func testExtensionsAreUniqueAcrossLanguages() {
        var seen: [String: String] = [:]
        for support in LanguageSupport.all {
            for ext in support.extensions {
                XCTAssertNil(seen[ext], "extension .\(ext) claimed by both \(seen[ext] ?? "") and \(support.id)")
                seen[ext] = support.id
            }
        }
    }

    func testProbeSamplesExtractExpectedUnitCounts() throws {
        for support in LanguageSupport.all {
            let sample = try XCTUnwrap(LanguageProbe.samples[support.id])
            let units = try UnitExtractor(support: support)
                .extract(source: sample.source, filePath: "probe.\(support.extensions.first!)")
            XCTAssertEqual(units.count, sample.expectedUnits, "\(support.id): \(units.map(\.name))")
            XCTAssertTrue(units.allSatisfy { $0.language == support.id })
            XCTAssertTrue(units.allSatisfy { !$0.name.isEmpty && $0.name != "<anonymous>" },
                          "\(support.id) produced an unnamed unit: \(units.map(\.name))")
        }
    }

    /// The shared snippet is the same shape in every language, so the score decomposes the
    /// same way. These are hand-counted, not recorded from output.
    func testComplexityOfTheSharedSnippet() throws {
        let expected: [String: Int] = [
            "swift": 6,       // guard + for + if + && + one case (default free)
            "c": 5,           // if + && + for + one case
            "cpp": 4,         // if + || + for
            "csharp": 5,      // if + && + foreach + one case
            "python": 4,      // if + and + for
            "javascript": 5,  // if + && + for-of + one case
            "typescript": 4,  // if + && + for-of
            "tsx": 3,         // if + &&
            "java": 5,        // if + && + for + one case
            "kotlin": 5,      // if + && + for + one when entry (else free)
            "rust": 6,        // if + && + for + both match arms
            "go": 5,          // if + && + for + one case
            "ruby": 5,        // if-modifier + && + for + one when
            "php": 5,         // if + && + foreach + one case
        ]
        for (id, complexity) in expected {
            let support = try XCTUnwrap(LanguageSupport.all.first { $0.id == id })
            let sample = try XCTUnwrap(LanguageProbe.samples[id])
            let units = try UnitExtractor(support: support)
                .extract(source: sample.source, filePath: "probe.\(support.extensions.first!)")
            let work = try XCTUnwrap(units.first { $0.name.lowercased().hasSuffix("work") },
                                     "\(id): no work function in \(units.map(\.name))")
            XCTAssertEqual(work.complexity, complexity, "\(id) complexity")
        }
    }

    /// A short-circuit operator is a branch; arithmetic and comparison are not. They share
    /// one node type in every C-family grammar, so this is the check that keeps `a + b`
    /// from scoring like `a && b`.
    func testOnlyShortCircuitOperatorsCount() throws {
        let cases: [(String, String, Int)] = [
            ("c", "int f(int a, int b) { return a + b; }", 1),
            ("c", "int f(int a, int b) { return a && b; }", 2),
            ("c", "int f(int a, int b) { return a > b; }", 1),
            ("python", "def f(a, b):\n    return a + b\n", 1),
            ("python", "def f(a, b):\n    return a and b\n", 2),
            ("javascript", "function f(a, b) { return a + b; }", 1),
            ("javascript", "function f(a, b) { return a ?? b; }", 2),
            ("ruby", "def f(a, b)\n  a + b\nend\n", 1),
            ("ruby", "def f(a, b)\n  a || b\nend\n", 2),
        ]
        for (id, source, complexity) in cases {
            let support = try XCTUnwrap(LanguageSupport.all.first { $0.id == id })
            let units = try UnitExtractor(support: support)
                .extract(source: source, filePath: "t.\(support.extensions.first!)")
            XCTAssertEqual(units.first { $0.name == "f" }?.complexity, complexity, "\(id): \(source)")
        }
    }

    /// Keyword tokens must not be counted alongside the statements they introduce.
    func testKeywordTokensAreNotCountedTwice() throws {
        let units = try UnitExtractor(support: .ruby)
            .extract(source: "def f(x)\n  for i in 0..x do end\n  x\nend\n", filePath: "t.rb")
        XCTAssertEqual(units.first { $0.name == "f" }?.complexity, 2, "one `for`, counted once")
    }

    func testCSSCountsDeclarationsBecauseItHasNoBranches() throws {
        let units = try UnitExtractor(support: .css)
            .extract(source: ".a { color: red; margin: 0; padding: 1px; }", filePath: "t.css")
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].complexity, 4, "base + three declarations")
        XCTAssertEqual(units[0].language, "css")
    }

    func testRegistryMapsExtensionsIncludingCase() {
        XCTAssertEqual(LanguageRegistry.shared.language(forExtension: "py")?.id, "python")
        XCTAssertEqual(LanguageRegistry.shared.language(forExtension: "TS")?.id, "typescript")
        XCTAssertEqual(LanguageRegistry.shared.language(forExtension: "hpp")?.id, "cpp")
        XCTAssertNil(LanguageRegistry.shared.language(forExtension: "md"))
    }

    func testMalformedSourceInAnyLanguageDoesNotThrow() throws {
        for support in LanguageSupport.all {
            let extractor = try UnitExtractor(support: support)
            XCTAssertNoThrow(try extractor.extract(source: "((( unterminated {{{", filePath: "x"))
            XCTAssertNoThrow(try extractor.extract(source: "", filePath: "x"))
        }
    }

    func testVendoredScannerVersionsMatchPackageResolved() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var resolvedURL: URL?
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Package.resolved")
            if FileManager.default.fileExists(atPath: candidate.path) {
                resolvedURL = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let url = try XCTUnwrap(resolvedURL, "Package.resolved not found")
        struct Resolved: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { let version: String? }
                let identity: String
                let state: State
            }
            let pins: [Pin]
        }
        let decoded = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: url))
        let versions = Dictionary(uniqueKeysWithValues: decoded.pins.compactMap { pin in
            pin.state.version.map { (pin.identity, $0) }
        })
        XCTAssertEqual(versions["tree-sitter-python"], "0.25.0")
        XCTAssertEqual(versions["tree-sitter-javascript"], "0.25.0")
        XCTAssertEqual(versions["tree-sitter-css"], "0.25.0")
    }

    func testRustTraitImplQualifiesMethodsWithTargetTypeRatherThanTrait() throws {
        let source = """
        trait Display {}
        struct Widget {}
        impl Display for Widget {
            fn fmt(&self) -> i32 { 0 }
        }
        """
        let units = try UnitExtractor(support: .rust).extract(source: source, filePath: "widget.rs")
        XCTAssertTrue(units.contains { $0.name == "Widget.fmt" }, "\(units.map(\.name))")
        XCTAssertFalse(units.contains { $0.name == "Display.fmt" }, "\(units.map(\.name))")
    }
}
