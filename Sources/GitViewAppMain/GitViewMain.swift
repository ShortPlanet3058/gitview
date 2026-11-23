import SwiftUI
import GitViewUI

@main
struct GitViewMainApp: App {
    @NSApplicationDelegateAdaptor(GitViewAppDelegate.self) private var delegate
    @State private var preferences = AppPreferences.shared
    @FocusedValue(\.workspaceSession) private var focusedSession

    private var preferredScheme: ColorScheme? {
        switch preferences.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some Scene {
        WindowGroup("GitView") {
            WorkspaceWindowView(preferences: preferences)
                .frame(minWidth: 1100, minHeight: 640)
                .preferredColorScheme(preferredScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 820)
        .commands {
            GitViewCommands(session: focusedSession, preferences: preferences)
        }

        Settings {
            SettingsView(preferences: preferences)
                .preferredColorScheme(preferredScheme)
        }
    }
}
