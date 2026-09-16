// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitView",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GitViewCore", targets: ["GitViewCore"]),
        .library(name: "GitViewGit", targets: ["GitViewGit"]),
        .executable(name: "gitview-cli", targets: ["gitview-cli"]),
    ],
    targets: [
        // Pure models + analysis. Must never import any UI framework.
        .target(name: "GitViewCore"),

        // Process wrapper around /usr/bin/git, plus incremental log/diff parsing.
        .target(name: "GitViewGit", dependencies: ["GitViewCore"]),

        .executableTarget(name: "gitview-cli", dependencies: ["GitViewCore", "GitViewGit"]),

        .testTarget(name: "GitViewGitTests", dependencies: ["GitViewGit", "GitViewCore"]),
    ]
)
