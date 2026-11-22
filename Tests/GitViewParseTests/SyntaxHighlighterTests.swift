import XCTest
@testable import GitViewParse

final class SyntaxHighlighterTests: XCTestCase {

    private func slice(_ text: String, range: Range<Int>) -> String? {
        let utf16 = text.utf16
        guard range.lowerBound >= 0, range.upperBound <= utf16.count, range.lowerBound < range.upperBound else {
            return nil
        }
        let uStart = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let uEnd = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        guard let start = String.Index(uStart, within: text),
              let end = String.Index(uEnd, within: text) else {
            return nil
        }
        return String(text[start..<end])
    }

    func testUnsupportedExtensionReturnsEmpty() {
        let spans = SyntaxHighlighter.highlightLines(source: "hello world\n", filePath: "notes.txt")
        XCTAssertTrue(spans.isEmpty)
    }

    func testSwiftKeywordsTypesStringsNumbersAndComments() {
        let source = """
        // Greeting helper
        struct Greeter {
            func greet(name: String) -> Int {
                let text = "hello"
                return 42
            }
        }
        """
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let spans = SyntaxHighlighter.highlightLines(source: source, filePath: "Sources/Greeter.swift")
        XCTAssertEqual(spans.count, lines.count)

        XCTAssertEqual(spans[0].map(\.kind), [.comment])
        XCTAssertEqual(slice(lines[0], range: spans[0][0].range), "// Greeting helper")

        let structLineKinds = spans[1].map(\.kind)
        XCTAssertTrue(structLineKinds.contains(.keyword))
        XCTAssertTrue(structLineKinds.contains(.type))

        let funcTokens = spans[2].compactMap { span -> (SyntaxTokenKind, String)? in
            guard let text = slice(lines[2], range: span.range) else { return nil }
            return (span.kind, text)
        }
        XCTAssertTrue(funcTokens.contains { $0.0 == .keyword && $0.1 == "func" })
        XCTAssertTrue(funcTokens.contains { $0.0 == .function && $0.1 == "greet" })
        XCTAssertTrue(funcTokens.contains { $0.0 == .type && $0.1 == "String" })

        let stringTokens = spans[3].compactMap { span -> (SyntaxTokenKind, String)? in
            guard let text = slice(lines[3], range: span.range) else { return nil }
            return (span.kind, text)
        }
        XCTAssertTrue(stringTokens.contains { $0.0 == .keyword && $0.1 == "let" })
        XCTAssertTrue(stringTokens.contains { $0.0 == .string })

        let returnTokens = spans[4].compactMap { span -> (SyntaxTokenKind, String)? in
            guard let text = slice(lines[4], range: span.range) else { return nil }
            return (span.kind, text)
        }
        XCTAssertTrue(returnTokens.contains { $0.0 == .keyword && $0.1 == "return" })
        XCTAssertTrue(returnTokens.contains { $0.0 == .number && $0.1 == "42" })
    }

    func testPythonHighlighting() {
        let source = """
        # compute sum
        def total(values):
            if len(values) > 0:
                return "ok"
            return 0
        """
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let spans = SyntaxHighlighter.highlightLines(source: source, filePath: "scripts/calc.py")
        XCTAssertEqual(spans.count, lines.count)
        XCTAssertEqual(spans[0].first?.kind, .comment)
        XCTAssertTrue(spans[1].contains { $0.kind == .keyword && slice(lines[1], range: $0.range) == "def" })
        XCTAssertTrue(spans[1].contains { $0.kind == .function && slice(lines[1], range: $0.range) == "total" })
        XCTAssertTrue(spans[3].contains { $0.kind == .string })
        XCTAssertTrue(spans[4].contains { $0.kind == .number && slice(lines[4], range: $0.range) == "0" })
    }

    func testTypeScriptHighlighting() {
        let source = """
        interface User {
            name: string
        }
        function formatUser(user: User): number {
            return 100
        }
        """
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let spans = SyntaxHighlighter.highlightLines(source: source, filePath: "web/user.ts")
        XCTAssertEqual(spans.count, lines.count)
        XCTAssertTrue(spans[0].contains { $0.kind == .type && slice(lines[0], range: $0.range) == "User" })
        XCTAssertTrue(spans[3].contains { $0.kind == .function && slice(lines[3], range: $0.range) == "formatUser" })
        XCTAssertTrue(spans[3].contains { $0.kind == .type && slice(lines[3], range: $0.range) == "User" })
        XCTAssertTrue(spans[4].contains { $0.kind == .number && slice(lines[4], range: $0.range) == "100" })
    }

    func testMultilineBlockCommentAndUnicodeUTF16Safety() {
        let source = """
        /* line one 🌟
           line two */
        let badge = "🚀 Café"
        let count = 99
        """
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let spans = SyntaxHighlighter.highlightLines(source: source, filePath: "Unicode.swift")
        XCTAssertEqual(spans.count, lines.count)
        XCTAssertEqual(spans[0].first?.kind, .comment)
        XCTAssertEqual(spans[1].first?.kind, .comment)

        // Every returned span must sit cleanly on UTF-16 character boundaries without splitting surrogates.
        for (lineIndex, lineText) in lines.enumerated() {
            for span in spans[lineIndex] {
                XCTAssertNotNil(slice(lineText, range: span.range),
                                "Invalid UTF-16 span \(span.range) on line: \(lineText)")
            }
        }
        XCTAssertTrue(spans[2].contains { $0.kind == .string })
        XCTAssertTrue(spans[3].contains { $0.kind == .number && slice(lines[3], range: $0.range) == "99" })
    }

    func testHighlightDiffLinesMapsOldAndNewSides() {
        let inputs = [
            DiffHighlightLineInput(id: 1, text: "func sample() -> Int {", includesInOld: true, includesInNew: true),
            DiffHighlightLineInput(id: 2, text: "    return 1", includesInOld: true, includesInNew: false),
            DiffHighlightLineInput(id: 3, text: "    return 2 // updated", includesInOld: false, includesInNew: true),
            DiffHighlightLineInput(id: 4, text: "}", includesInOld: true, includesInNew: true),
        ]
        let map = SyntaxHighlighter.highlightDiffLines(inputs, filePath: "Sample.swift")
        XCTAssertTrue(map[1]?.contains(where: { $0.kind == .keyword }) ?? false)
        XCTAssertTrue(map[2]?.contains(where: { $0.kind == .number }) ?? false)
        XCTAssertTrue(map[3]?.contains(where: { $0.kind == .comment }) ?? false)
    }
}
