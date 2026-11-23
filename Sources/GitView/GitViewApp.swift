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

@MainActor
final class ExternalOpenRouter {
    static let shared = ExternalOpenRouter()
    static let openNotification = Notification.Name("GitViewOpenRepositoryURL")

    private var pendingURL: URL?

    private init() {}

    func enqueue(_ urls: [URL]) {
        guard let first = urls.first, let target = Self.repositoryDirectoryURL(from: first) else { return }
        pendingURL = target
        NotificationCenter.default.post(name: Self.openNotification, object: nil)
    }

    func consumePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }

    static func repositoryDirectoryURL(from url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir) {
            return isDir.boolValue ? standardized : standardized.deletingLastPathComponent()
        }
        return standardized
    }
}

public struct WorkspaceWindowView: View {
    @Environment(\.controlActiveState) private var controlActiveState
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
            .onAppear {
                if let url = ExternalOpenRouter.shared.consumePendingURL() {
                    session.open(url: url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ExternalOpenRouter.openNotification)) { _ in
                if controlActiveState == .key {
                    if let url = ExternalOpenRouter.shared.consumePendingURL() {
                        session.open(url: url)
                    }
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(40))
                        if let url = ExternalOpenRouter.shared.consumePendingURL() {
                            session.open(url: url)
                        }
                    }
                }
            }
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

            Button("Clone Repository…") {
                session?.navigation.isCloneSheetPresented = true
            }
            .disabled(session == nil)

            Button("New Repository…") {
                session?.navigation.isInitSheetPresented = true
            }
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

            let screens = session?.visibleScreens ?? NavigationStore.standardScreens
            ForEach(Array(screens.prefix(9).enumerated()), id: \.element) { index, screen in
                Button(screen.displayTitle(advanced: preferences.advanced)) { session?.show(screen) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(!(session?.hasRepository ?? false))
            }

            Divider()

            Toggle("Advanced Mode", isOn: $preferences.advanced)
                .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Larger Code Font") { preferences.increaseCodeFontSize() }
                .keyboardShortcut("=", modifiers: .command)

            Button("Smaller Code Font") { preferences.decreaseCodeFontSize() }
                .keyboardShortcut("-", modifiers: .command)

            Button("Reset Code Font Size") { preferences.resetCodeFontSize() }
                .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Button("Command Palette…") {
                session?.navigation.isShortcutsSheetPresented = false
                session?.navigation.isCommandPalettePresented.toggle()
            }
            .keyboardShortcut("k")
            .disabled(session == nil)

            Button("Keyboard Shortcuts…") {
                session?.navigation.isCommandPalettePresented = false
                session?.navigation.isShortcutsSheetPresented.toggle()
            }
            .keyboardShortcut("/")
            .disabled(session == nil)

            Button("Find…") {
                guard let session else { return }
                let localScreens: Set<NavigationStore.Screen> = [
                    .files, .commits, .hotspots, .branches, .contributors, .releases
                ]
                let showingInlineDiff = session.navigation.screen == .changes
                    && session.inspector.inlineDiffRequest != nil
                let usesLocalFind = session.inspector.diffRequest != nil
                    || (!session.search.isSearching
                        && session.inspector.fileHistoryPath == nil
                        && (showingInlineDiff || localScreens.contains(session.navigation.screen)))
                if usesLocalFind {
                    session.navigation.focusLocalFindRequest += 1
                } else {
                    session.navigation.focusSearchRequest += 1
                }
            }
            .keyboardShortcut("f")
            .disabled(!(session?.hasRepository ?? false))

            Button("Find in Repository…") {
                session?.navigation.focusSearchRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!(session?.hasRepository ?? false))

            Button("Clear Search") { session?.search.clear() }
                .disabled(!(session?.search.isSearching ?? false))
        }
    }
}

/// Without this the process launches as an accessory when run straight from SwiftPM
/// (`swift run GitView`), leaving the window behind other apps without a menu bar.
@MainActor
public final class GitViewAppDelegate: NSObject, NSApplicationDelegate {
    private var headlessScreenshotSession: WorkspaceSession?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--screenshot") {
            headlessScreenshotSession = WorkspaceSession.makeForLaunchArgumentsIfNeeded(preferences: .shared)
        }
        guard Bundle.main.bundleIdentifier == nil else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpenRouter.shared.enqueue(urls)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        CommandLine.arguments.contains("--screenshot")
    }
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
