import SwiftUI
import AppKit
import GitViewCore

private struct FocusedWorkspaceSessionKey: FocusedValueKey {
    typealias Value = WorkspaceSession
}

public extension FocusedValues {
    var workspaceSession: WorkspaceSession? {
        get { self[FocusedWorkspaceSessionKey.self] }
        set { self[FocusedWorkspaceSessionKey.self] = newValue }
    }
}

public extension View {
    func withWorkspaceEnvironment(_ session: WorkspaceSession) -> some View {
        self
            .environment(session)
            .environment(session.preferences)
            .environment(session.navigation)
            .environment(session.risk)
            .environment(session.workingCopy)
            .environment(session.search)
            .environment(session.inspector)
    }
}

public struct WorkspaceWindowView: View {
    @State private var session: WorkspaceSession

    public init(preferences: AppPreferences) {
        _session = State(initialValue: WorkspaceSession(
            preferences: preferences,
            consumeLaunchArgumentsIfAvailable: true
        ))
    }

    public var body: some View {
        AppShell()
            .withWorkspaceEnvironment(session)
            .focusedSceneValue(\.workspaceSession, session)
    }
}

public struct GitViewCommands: Commands {
    private let session: WorkspaceSession?
    @Bindable private var preferences: AppPreferences

    public init(session: WorkspaceSession?, preferences: AppPreferences) {
        self.session = session
        self.preferences = preferences
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Repository…") {
                if let session { chooseRepository(into: session) }
            }
            .keyboardShortcut("o")
            .disabled(session == nil)

            Menu("Open Recent") {
                ForEach(RecentRepositories.all(), id: \.path) { url in
                    Button(url.lastPathComponent) { session?.open(url: url) }
                }
                if !RecentRepositories.all().isEmpty {
                    Divider()
                    Button("Clear Menu") { RecentRepositories.clear() }
                }
            }
            .disabled(session == nil || RecentRepositories.all().isEmpty)
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") { session?.refresh() }
                .keyboardShortcut("r")
                .disabled(!(session?.hasRepository ?? false) || (session?.isRefreshing ?? false))

            Button("Back") { session?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(session?.canGoBack ?? false))

            Divider()

            let screens = session?.visibleScreens ?? NavigationStore.repositoryScreens
            ForEach(Array(screens.prefix(9).enumerated()), id: \.element) { index, screen in
                Button(screen.title) { session?.show(screen) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(!(session?.hasRepository ?? false))
            }

            Divider()

            Toggle("Advanced Mode", isOn: $preferences.advanced)
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { session?.navigation.focusSearchRequest += 1 }
                .keyboardShortcut("f")
                .disabled(!(session?.hasRepository ?? false))

            Button("Clear Search") { session?.search.clear() }
                .disabled(!(session?.search.isSearching ?? false))
        }
    }
}

/// Without this the process launches as an accessory when run straight from SwiftPM
/// (`swift run GitView`), leaving the window behind other apps without a menu bar.
public final class GitViewAppDelegate: NSObject, NSApplicationDelegate {
    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleIdentifier == nil else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
public func chooseRepository(into session: WorkspaceSession) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Analyse"
    panel.message = "Choose a git repository to analyse"
    if panel.runModal() == .OK, let url = panel.url {
        session.open(url: url)
    }
}
