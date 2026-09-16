// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitView",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GitViewCore", targets: ["GitViewCore"]),
        .library(name: "GitViewParse", targets: ["GitViewParse"]),
        .library(name: "GitViewGit", targets: ["GitViewGit"]),
        .executable(name: "gitview-cli", targets: ["gitview-cli"]),
        .executable(name: "GitView", targets: ["GitView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        // The main branch does not contain the generated parser.c — it is produced at build
        // time by the tree-sitter CLI, which needs node. The `-with-generated-files` tags
        // ship it pre-generated, which is what makes this consumable from SwiftPM alone.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift",
                 exact: "0.7.3-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java", exact: "0.23.5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-php", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c-sharp", exact: "0.23.5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.25.0"),
        .package(url: "https://github.com/fwcd/tree-sitter-kotlin", exact: "0.3.8"),
    ],
    targets: [
        // Pure models + analysis. Must never import any UI framework.
        .target(name: "GitViewCore"),

        // Process wrapper around /usr/bin/git, plus incremental log/diff parsing.
        .target(name: "GitViewGit", dependencies: ["GitViewCore"]),

        // External scanners for three grammars whose manifests drop them — see the
        // README in that directory.
        .target(name: "CGrammarScanners",
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("include")]),

        // tree-sitter parsing, function extraction, complexity metrics.
        .target(
            name: "GitViewParse",
            dependencies: [
                "GitViewCore",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                "CGrammarScanners",
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterPHP", package: "tree-sitter-php"),
                .product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterKotlin", package: "tree-sitter-kotlin"),
            ]
        ),

        .executableTarget(name: "gitview-cli", dependencies: ["GitViewCore", "GitViewGit", "GitViewParse"]),

        // SwiftUI app. Nothing below this line may be imported by Core/Git/Parse.
        .executableTarget(
            name: "GitView",
            dependencies: ["GitViewCore", "GitViewGit", "GitViewParse"]
        ),

        .testTarget(name: "GitViewCoreTests", dependencies: ["GitViewCore"]),
        .testTarget(name: "GitViewGitTests", dependencies: ["GitViewGit", "GitViewCore"]),
        .testTarget(name: "GitViewParseTests", dependencies: ["GitViewParse", "GitViewCore"]),
    ]
)
