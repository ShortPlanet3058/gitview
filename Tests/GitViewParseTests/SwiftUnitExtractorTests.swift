import XCTest
@testable import GitViewParse
import GitViewCore

final class SwiftUnitExtractorTests: XCTestCase {

    private func units(_ source: String) throws -> [CodeUnit] {
        try SwiftUnitExtractor().extract(source: source, filePath: "T.swift")
    }

    private func unit(_ source: String, named name: String) throws -> CodeUnit {
        let all = try units(source)
        guard let match = all.first(where: { $0.name == name }) else {
            XCTFail("no unit named \(name); got \(all.map(\.name))")
            throw XCTSkip("missing unit")
        }
        return match
    }

    // MARK: - Line ranges

    func testLineRangeIsOneBasedAndInclusive() throws {
        let source = """
        // line 1
        func alpha() {
            print(1)
        }
        """
        let alpha = try unit(source, named: "alpha")
        XCTAssertEqual(alpha.lineRange, 2...4)
        XCTAssertEqual(alpha.lineCount, 3)
    }

    func testTrailingNewlineDoesNotExtendRange() throws {
        // A node ending at column 0 of the next line finished on the previous one.
        // Getting this wrong inflates lineCount for every unit in the codebase.
        let source = "func a() {\n    print(1)\n}\n\nfunc b() {\n}\n"
        let all = try units(source)
        XCTAssertEqual(all.first(where: { $0.name == "a" })?.lineRange, 1...3)
        XCTAssertEqual(all.first(where: { $0.name == "b" })?.lineRange, 5...6)
    }

    // MARK: - Complexity

    func testStraightLineFunctionHasComplexityOne() throws {
        XCTAssertEqual(try unit("func a() { print(1) }", named: "a").complexity, 1)
    }

    func testEachBranchFormCountsOnce() throws {
        let cases: [(String, Int)] = [
            ("func a() { if x { } }", 2),
            ("func a() { guard x else { return } }", 2),
            ("func a() { for i in y { } }", 2),
            ("func a() { while x { } }", 2),
            ("func a() { repeat { } while x }", 2),
            ("func a() { do { } catch { } }", 2),
            ("func a() { let v = x ? 1 : 2 }", 2),
            ("func a() { let v = x && y }", 2),
            ("func a() { let v = x || y }", 2),
            ("func a() { let v = x ?? y }", 2),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(try unit(source, named: "a").complexity, expected, source)
        }
    }

    func testSwitchCountsCasesButNotDefault() throws {
        // The arm marker node is `default_keyword`; matching on "default" silently
        // counts the fall-through arm as a decision point.
        let source = """
        func a() {
            switch x {
            case 1: break
            case 2: break
            default: break
            }
        }
        """
        XCTAssertEqual(try unit(source, named: "a").complexity, 3)
    }

    func testSwitchWithNoDefaultCountsEveryCase() throws {
        let source = """
        func a() {
            switch x {
            case 1: break
            case 2: break
            case 3: break
            }
        }
        """
        XCTAssertEqual(try unit(source, named: "a").complexity, 4)
    }

    // MARK: - Pruning

    func testTypeComplexityExcludesItsMethods() throws {
        // Without pruning a type accumulates every method's branches and would outrank
        // every function, making the whole ranking useless.
        let source = """
        struct S {
            func heavy() {
                if a { }
                if b { }
                if c { }
            }
        }
        """
        XCTAssertEqual(try unit(source, named: "S").complexity, 1)
        XCTAssertEqual(try unit(source, named: "S.heavy").complexity, 4)
    }

    func testNestedFunctionIsItsOwnUnitAndPrunedFromParent() throws {
        let source = """
        func outer() {
            if a { }
            func inner() {
                if b { }
                if c { }
            }
        }
        """
        XCTAssertEqual(try unit(source, named: "outer").complexity, 2)
        XCTAssertEqual(try unit(source, named: "inner").complexity, 3)
    }

    func testClosureComplexityStaysWithEnclosingFunction() throws {
        // Closures are not separate units on purpose: their branches are the
        // enclosing function's branches.
        let source = """
        func outer() {
            items.forEach { item in
                if item.flag { }
            }
        }
        """
        XCTAssertEqual(try unit(source, named: "outer").complexity, 2)
    }

    // MARK: - Nesting depth

    func testNestingDepthCountsControlFlow() throws {
        let source = """
        func a() {
            if x {
                for i in y {
                    while z { }
                }
            }
        }
        """
        XCTAssertEqual(try unit(source, named: "a").nestingDepth, 3)
    }

    func testGuardDoesNotCountAsNesting() throws {
        // A guard is an early exit; its body does not contain what follows. Counting it
        // would penalise the idiom that reduces nesting.
        let source = """
        func a() {
            guard x else { return }
            guard y else { return }
            print(1)
        }
        """
        let a = try unit(source, named: "a")
        XCTAssertEqual(a.nestingDepth, 0)
        XCTAssertEqual(a.complexity, 3)
    }

    // MARK: - Declaration coverage

    func testComputedPropertyIsAUnitButStoredPropertyIsNot() throws {
        let source = """
        struct S {
            var stored: Int = 0
            var computed: Int {
                if x { return 1 }
                return 2
            }
        }
        """
        let all = try units(source)
        XCTAssertFalse(all.contains { $0.name == "S.stored" })
        XCTAssertEqual(try unit(source, named: "S.computed").complexity, 2)
    }

    func testInitDeinitAndSubscript() throws {
        let source = """
        class C {
            init() { if x { } }
            deinit { }
            subscript(i: Int) -> Int { return i }
        }
        """
        let names = Set(try units(source).map(\.name))
        XCTAssertTrue(names.contains("C.init"), "\(names)")
        XCTAssertTrue(names.contains("C.deinit"), "\(names)")
        XCTAssertTrue(names.contains("C.subscript"), "\(names)")
    }

    func testKindClassification() throws {
        let source = """
        func topLevel() { }
        struct S {
            func method() { }
        }
        protocol P { }
        """
        XCTAssertEqual(try unit(source, named: "topLevel").kind, .function)
        XCTAssertEqual(try unit(source, named: "S.method").kind, .method)
        XCTAssertEqual(try unit(source, named: "S").kind, .class)
        XCTAssertEqual(try unit(source, named: "P").kind, .class)
    }

    func testNamesAreQualifiedByEnclosingTypes() throws {
        let source = """
        enum Outer {
            struct Inner {
                func work() { }
            }
        }
        extension Outer {
            func extra() { }
        }
        """
        let names = Set(try units(source).map(\.name))
        XCTAssertTrue(names.contains("Outer.Inner.work"), "\(names)")
        XCTAssertTrue(names.contains("Outer.extra"), "\(names)")
    }

    // MARK: - Robustness

    func testMalformedSourceDoesNotCrashAndStillYieldsUnits() throws {
        // tree-sitter is error-tolerant; a half-written file mid-edit must not abort a scan.
        let source = """
        func good() { if x { } }
        func broken( {
        """
        XCTAssertNoThrow(try units(source))
        XCTAssertTrue(try units(source).contains { $0.name == "good" })
    }

    func testEmptyAndCommentOnlySource() throws {
        XCTAssertEqual(try units("").count, 0)
        XCTAssertEqual(try units("// nothing here\n").count, 0)
    }

    func testUnicodeInSourceKeepsRangesCorrect() throws {
        // Node ranges are UTF-16 offsets; emoji are surrogate pairs. If name extraction
        // used byte offsets instead, this would slice mid-character.
        let source = """
        func alpha() {
            let s = "🚀🚀🚀 emoji"
        }
        func beta() { }
        """
        XCTAssertEqual(try unit(source, named: "beta").lineRange, 4...4)
        XCTAssertEqual(try unit(source, named: "alpha").name, "alpha")
    }
}
