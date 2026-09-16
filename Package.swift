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
    ],
    targets: [
        // Pure models + analysis. Must never import any UI framework.
        .target(name: "GitViewCore"),

        // Process wrapper around /usr/bin/git, plus incremental log/diff parsing.
        .target(name: "GitViewGit", dependencies: ["GitViewCore"]),

        // tree-sitter parsing, function extraction, complexity metrics.
        .target(
            name: "GitViewParse",
            dependencies: [
                "GitViewCore",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
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
