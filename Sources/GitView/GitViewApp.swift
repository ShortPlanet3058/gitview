import SwiftUI
import AppKit
import GitViewCore

@main
struct GitViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AnalysisModel()

    var body: some Scene {
        WindowGroup("GitView") {
            AppShell()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 640)
                .preferredColorScheme(nil)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { chooseRepository(into: model) }
                    .keyboardShortcut("o")
                // Built fresh each time the menu opens, so a repository deleted since
                // launch is not offered.
                Menu("Open Recent") {
                    ForEach(RecentRepositories.all(), id: \.path) { url in
                        Button(url.lastPathComponent) { model.open(url: url) }
                    }
                    if !RecentRepositories.all().isEmpty {
                        Divider()
                        Button("Clear Menu") { RecentRepositories.clear() }
                    }
                }
                .disabled(RecentRepositories.all().isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(!model.hasRepository || model.isRefreshing)
                // Escape does this too, from the view itself, so it is not listed twice.
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!model.canGoBack)
                Divider()
                // Numbered from what the sidebar shows, so ⌘4 is always the fourth item
                // on screen. Past nine there is no obvious key, and the sidebar is right
                // there, so the rest go unshortcut rather than onto arbitrary keys.
                ForEach(Array(model.visibleScreens.prefix(9).enumerated()), id: \.element) { index, screen in
                    Button(screen.title) { model.show(screen) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                        .disabled(!model.hasRepository)
                }
                Divider()
                Toggle("Advanced Mode", isOn: $model.advanced)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",")
                    .disabled(!model.hasRepository)
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { model.focusSearchRequest += 1 }
                    .keyboardShortcut("f")
                    .disabled(!model.hasRepository)
                Button("Clear Search") { model.clearSearch() }
                    .disabled(!model.isSearching)
            }
        }
    }
}

/// Without this the process launches as an accessory when run straight from SwiftPM
/// (`swift run GitView`), which leaves the window behind other apps and with no menu bar.
/// A packaged .app gets this from its Info.plist instead, but the source of truth should
/// not depend on how the binary was launched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only the bare SwiftPM binary needs this; a bundle is already a regular app, and
        // forcing activation there would yank focus from whatever the user is doing.
        guard Bundle.main.bundleIdentifier == nil else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
func chooseRepository(into model: AnalysisModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Analyse"
    panel.message = "Choose a git repository to analyse"
    if panel.runModal() == .OK, let url = panel.url {
        model.open(url: url)
    }
}
