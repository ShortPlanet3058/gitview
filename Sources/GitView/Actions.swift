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

func openInTerminal(_ directory: URL) {
    NSWorkspace.shared.open(
        [directory],
        withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
        configuration: NSWorkspace.OpenConfiguration())
}

/// Opens a file in whichever app the user has already chosen for that file type.
///
/// Deliberately not a hardcoded editor: asking the system means the file opens in the
/// editor this person actually uses, without GitView holding a preference for it.
func openInEditor(_ url: URL) {
    NSWorkspace.shared.open(url)
}

/// Right-click actions for a path inside the repository. `path` is repository-relative,
/// which is what every model in GitView carries.
struct PathActions: View {
    @EnvironmentObject private var model: AnalysisModel
    let path: String
    /// Hidden when the menu is already attached to the file-history view itself.
    var showsHistory = true

    private var absolute: URL? {
        model.analysis.map { $0.root.appendingPathComponent(path) }
    }

    var body: some View {
        if showsHistory {
            Button("Show File History") { model.showFileHistory(path) }
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
        if let web = model.analysis?.info.remoteWebURL,
           let branch = model.analysis?.info.currentBranch {
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
    @EnvironmentObject private var model: AnalysisModel
    let commit: Commit

    var body: some View {
        Button("Show This Commit") { model.selectedCommitSHA = commit.sha }
        Divider()
        Button("Copy SHA") { copyToPasteboard(commit.sha) }
        Button("Copy Short SHA") { copyToPasteboard(String(commit.sha.prefix(7))) }
        Button("Copy Subject") { copyToPasteboard(commit.subject) }
        Button("Copy Author") { copyToPasteboard(commit.author) }
        if let web = model.analysis?.info.remoteWebURL {
            Divider()
            Button("View on \(web.host ?? "Web")") {
                NSWorkspace.shared.open(web.appendingPathComponent("commit").appendingPathComponent(commit.sha))
            }
        }
    }
}

/// Right-click actions for a person.
struct PersonActions: View {
    @EnvironmentObject private var model: AnalysisModel
    let name: String

    var body: some View {
        Button("Show Their Work") { model.selectedAuthor = name }
        Button("Find Their Commits") { model.globalSearch = "author:\(name)" }
        Divider()
        Button("Copy Name") { copyToPasteboard(name) }
    }
}
