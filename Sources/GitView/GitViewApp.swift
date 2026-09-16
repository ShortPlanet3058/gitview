import SwiftUI
import AppKit

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
