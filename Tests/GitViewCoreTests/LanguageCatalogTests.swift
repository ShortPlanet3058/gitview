import XCTest
@testable import GitViewCore

final class LanguageCatalogTests: XCTestCase {
    private func name(_ path: String) -> String? { LanguageCatalog.language(forPath: path)?.name }

    func testIdentifiesFilesWithNoExtension() {
        // The whole point of the filename table: these are what people mean by "Docker
        // support", and none of them has an extension to match on.
        XCTAssertEqual(name("Dockerfile"), "Dockerfile")
        XCTAssertEqual(name("app/Dockerfile"), "Dockerfile")
        XCTAssertEqual(name("Containerfile"), "Dockerfile")
        XCTAssertEqual(name("Dockerfile.web"), "Dockerfile")
        XCTAssertEqual(name("web.dockerfile"), "Dockerfile")
        XCTAssertEqual(name("Makefile"), "Makefile")
        XCTAssertEqual(name("CMakeLists.txt"), "CMake")
        XCTAssertEqual(name("Gemfile"), "Ruby")
        XCTAssertEqual(name("Package.swift"), "Swift")
    }

    func testIdentifiesByExtension() {
        let expected: [String: String] = [
            "a.py": "Python", "a.rs": "Rust", "a.go": "Go", "a.tsx": "TSX", "a.ts": "TypeScript",
            "a.kt": "Kotlin", "a.rb": "Ruby", "a.php": "PHP", "a.cs": "C#", "a.cpp": "C++",
            "a.m": "Objective-C", "a.yml": "YAML", "a.tf": "HCL", "a.sh": "Shell",
            "a.md": "Markdown", "a.scss": "SCSS", "a.vue": "Vue", "a.sql": "SQL",
            "deep/nested/path/file.java": "Java",
        ]
        for (path, language) in expected {
            XCTAssertEqual(name(path), language, path)
        }
    }

    func testUnknownAndEdgeCases() {
        XCTAssertNil(name("a.unknownext"))
        XCTAssertNil(name("noextension"))
        XCTAssertNil(name(".hidden"), "a leading dot is not an extension")
        XCTAssertEqual(name(".gitignore"), "Ignore List", "but known dotfiles are still named")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(name("A.PY"), "Python")
        XCTAssertEqual(name("DOCKERFILE"), "Dockerfile")
    }

    func testKindsAreAssigned() {
        XCTAssertEqual(LanguageCatalog.language(forPath: "a.py")?.kind, .programming)
        XCTAssertEqual(LanguageCatalog.language(forPath: "a.md")?.kind, .prose)
        XCTAssertEqual(LanguageCatalog.language(forPath: "a.json")?.kind, .data)
        XCTAssertEqual(LanguageCatalog.language(forPath: "a.html")?.kind, .markup)
    }

    func testCatalogIsSubstantial() {
        XCTAssertGreaterThan(LanguageCatalog.count, 90, "the breakdown should recognise most of what people write")
    }

    /// Every language GitView can *parse* must also be *named*, or a repository could show
    /// hotspots for a language its own breakdown does not list.
    func testEveryParsedExtensionIsAlsoRecognised() {
        for ext in ["swift", "c", "cpp", "cs", "py", "js", "ts", "tsx", "java", "kt", "rs", "go", "rb", "php", "css"] {
            XCTAssertNotNil(LanguageCatalog.language(forPath: "file.\(ext)"), ".\(ext)")
        }
    }
}
