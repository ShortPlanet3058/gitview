import SwiftUI
import AppKit
import GitViewCore

// The small set of things a person wants to do *to* something they can see: reveal it,
// open it, copy it. Written once here so that every right-click offers the same verbs with
// the same wording, and so a fix to how an editor is launched is a fix everywhere.

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

@MainActor
func openInTerminal(_ directory: URL) {
    let bundleIDs: [String]
    switch AppPreferences.shared.preferredTerminal {
    case .terminal: bundleIDs = ["com.apple.Terminal"]
    case .iterm:    bundleIDs = ["com.googlecode.iterm2"]
    case .ghostty:  bundleIDs = ["com.mitchellh.ghostty"]
    case .warp:     bundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp"]
    case .wezterm:  bundleIDs = ["com.github.wez.wezterm"]
    }
    let appURL = bundleIDs.lazy
        .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        .first ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    NSWorkspace.shared.open([directory], withApplicationAt: appURL,
                            configuration: NSWorkspace.OpenConfiguration())
}

/// Opens a file (optionally jumping to `line`) using the configured editor or system default.
@MainActor
func openInEditor(_ url: URL, line: Int? = nil) {
    let chosen = AppPreferences.shared.preferredEditor
    if chosen == .system {
        NSWorkspace.shared.open(url)
        return
    }

    let candidates: [ExternalEditor] = chosen == .auto
        ? [.cursor, .vscode, .zed, .sublime, .xcode]
        : [chosen]

    for editor in candidates {
        let spec = editorSpec(for: editor)
        if let cliPath = spec.cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let args = line.map { spec.lineArgs(url.path, $0) } ?? [url.path]
            launchDetached(executablePath: cliPath, arguments: args, fallbackURL: url)
            return
        }
        if let appURL = spec.bundleIDs.lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first {
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
    }

    NSWorkspace.shared.open(url)
}

private struct EditorLaunchSpec {
    let cliPaths: [String]
    let bundleIDs: [String]
    let lineArgs: (String, Int) -> [String]
}

private func editorSpec(for editor: ExternalEditor) -> EditorLaunchSpec {
    switch editor {
    case .cursor:
        return EditorLaunchSpec(
            cliPaths: ["/opt/homebrew/bin/cursor", "/usr/local/bin/cursor",
                       "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"],
            bundleIDs: ["com.todesktop.230313mzl4w4u92"],
            lineArgs: { ["--goto", "\($0):\($1)"] }
        )
    case .vscode:
        return EditorLaunchSpec(
            cliPaths: ["/opt/homebrew/bin/code", "/usr/local/bin/code",
                       "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"],
            bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
            lineArgs: { ["--goto", "\($0):\($1)"] }
        )
    case .zed:
        return EditorLaunchSpec(
            cliPaths: ["/opt/homebrew/bin/zed", "/usr/local/bin/zed",
                       "/Applications/Zed.app/Contents/MacOS/cli"],
            bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"],
            lineArgs: { ["\($0):\($1)"] }
        )
    case .sublime:
        return EditorLaunchSpec(
            cliPaths: ["/opt/homebrew/bin/subl", "/usr/local/bin/subl",
                       "/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl"],
            bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"],
            lineArgs: { ["\($0):\($1)"] }
        )
    case .xcode:
        return EditorLaunchSpec(
            cliPaths: ["/usr/bin/xed"],
            bundleIDs: ["com.apple.dt.Xcode"],
            lineArgs: { ["--line", "\($1)", $0] }
        )
    case .auto, .system:
        return EditorLaunchSpec(cliPaths: [], bundleIDs: [], lineArgs: { path, _ in [path] })
    }
}

private func launchDetached(executablePath: String, arguments: [String], fallbackURL: URL) {
    Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            await MainActor.run {
                _ = NSWorkspace.shared.open(fallbackURL)
            }
        }
    }
}

/// Right-click actions for a path inside the repository. `path` is repository-relative,
/// which is what every model in GitView carries.
struct PathActions: View {
    @Environment(WorkspaceSession.self) private var session
    let path: String
    /// Hidden when the menu is already attached to the file-history view itself.
    var showsHistory = true

    private var absolute: URL? {
        session.analysis.map { $0.root.appendingPathComponent(path) }
    }

    var body: some View {
        if showsHistory {
            Button("Show File History") { session.inspector.showFileHistory(path) }
            Divider()
        }
        if let absolute, FileManager.default.fileExists(atPath: absolute.path) {
            Button("Open in Editor") { openInEditor(absolute) }
            Button("Reveal in Finder") { revealInFinder(absolute) }
            Divider()
        }
        Button("Copy Path") { copyToPasteboard(path) }
        if let absolute {
            Button("Copy Full Path") { copyToPasteboard(absolute.path) }
        }
        if let web = session.analysis?.info.remoteWebURL,
           let branch = session.analysis?.info.currentBranch {
            Button("View on \(web.host ?? "Web")") {
                // Both GitHub and GitLab use /blob/<ref>/<path>; a host that does not will
                // land on its own 404 rather than somewhere misleading.
                let target = web.appendingPathComponent("blob").appendingPathComponent(branch).appendingPathComponent(path)
                NSWorkspace.shared.open(target)
            }
        }
    }
}

/// Right-click actions for a commit.
struct CommitActions: View {
    @Environment(WorkspaceSession.self) private var session
    let commit: Commit

    var body: some View {
        Button("Show This Commit") { session.navigation.selectedCommitSHA = commit.sha }
        Divider()
        Button("Copy SHA") { copyToPasteboard(commit.sha) }
        Button("Copy Short SHA") { copyToPasteboard(String(commit.sha.prefix(7))) }
        Button("Copy Subject") { copyToPasteboard(commit.subject) }
        Button("Copy Author") { copyToPasteboard(commit.author) }
        if let web = session.analysis?.info.remoteWebURL {
            Divider()
            Button("View on \(web.host ?? "Web")") {
                NSWorkspace.shared.open(web.appendingPathComponent("commit").appendingPathComponent(commit.sha))
            }
        }
    }
}

/// Right-click actions for a person.
struct PersonActions: View {
    @Environment(WorkspaceSession.self) private var session
    let name: String

    var body: some View {
        Button("Show Their Work") { session.navigation.selectedAuthor = name }
        Button("Find Their Commits") { session.search.globalSearch = "author:\(name)" }
        Divider()
        Button("Copy Name") { copyToPasteboard(name) }
    }
}
