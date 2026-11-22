import Foundation
import Observation
import GitViewGit

public enum ExternalEditor: String, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case xcode = "xcode"
    case vscode = "vscode"
    case cursor = "cursor"
    case zed = "zed"
    case sublime = "sublime"
    case system = "system"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Auto-detect"
        case .xcode: return "Xcode"
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .sublime: return "Sublime Text"
        case .system: return "System Default"
        }
    }
}

public enum ExternalTerminal: String, CaseIterable, Identifiable, Sendable {
    case terminal = "terminal"
    case iterm = "iterm"
    case ghostty = "ghostty"
    case warp = "warp"
    case wezterm = "wezterm"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .wezterm: return "WezTerm"
        }
    }
}

/// Persisted application-wide settings shared across windows and observed by sessions.
@MainActor
@Observable
public final class AppPreferences {
    public enum ChangeKind: Sendable {
        case riskModel
        case coupling
        case identity
        case environment
    }

    public static let shared = AppPreferences()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [UUID: (ChangeKind) -> Void] = [:]

    public var advanced: Bool {
        didSet {
            defaults.set(advanced, forKey: "advancedMode")
            notify(.environment)
        }
    }

    public var halfLifeDays: Double {
        didSet {
            defaults.set(halfLifeDays, forKey: "halfLifeDays")
            notify(.riskModel)
        }
    }

    public var excludeTests: Bool {
        didSet {
            defaults.set(excludeTests, forKey: "excludeTests")
            notify(.riskModel)
        }
    }

    public var excludeGenerated: Bool {
        didSet {
            defaults.set(excludeGenerated, forKey: "excludeGenerated")
            notify(.riskModel)
        }
    }

    public var ignoredPaths: String {
        didSet {
            defaults.set(ignoredPaths, forKey: "ignoredPaths")
            notify(.riskModel)
        }
    }

    public var minimumCommits: Int {
        didSet {
            defaults.set(minimumCommits, forKey: "minimumCommits")
            notify(.riskModel)
        }
    }

    public var minSharedCommits: Int {
        didSet {
            defaults.set(minSharedCommits, forKey: "minSharedCommits")
            notify(.coupling)
        }
    }

    public var identityName: String {
        didSet {
            defaults.set(identityName, forKey: "identityName")
            notify(.identity)
        }
    }

    public var identityEmail: String {
        didSet {
            defaults.set(identityEmail, forKey: "identityEmail")
            notify(.identity)
        }
    }

    public var gitExecutablePath: String {
        didSet {
            defaults.set(gitExecutablePath, forKey: GitProcess.gitExecutablePreferenceKey)
            notify(.environment)
        }
    }

    public var preferredEditor: ExternalEditor {
        didSet {
            defaults.set(preferredEditor.rawValue, forKey: "preferredEditor")
            notify(.environment)
        }
    }

    public var preferredTerminal: ExternalTerminal {
        didSet {
            defaults.set(preferredTerminal.rawValue, forKey: "preferredTerminal")
            notify(.environment)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.advanced = defaults.bool(forKey: "advancedMode")
        let storedHalfLife = defaults.object(forKey: "halfLifeDays") as? Double ?? 365
        self.halfLifeDays = min(max(storedHalfLife, 30), 1095)
        self.excludeTests = defaults.object(forKey: "excludeTests") as? Bool ?? true
        self.excludeGenerated = defaults.object(forKey: "excludeGenerated") as? Bool ?? true
        self.ignoredPaths = defaults.string(forKey: "ignoredPaths") ?? ""
        let storedMinCommits = defaults.object(forKey: "minimumCommits") as? Int ?? 1
        self.minimumCommits = max(1, storedMinCommits)
        let storedMinShared = defaults.object(forKey: "minSharedCommits") as? Int ?? 3
        self.minSharedCommits = max(2, storedMinShared)
        self.identityName = defaults.string(forKey: "identityName") ?? ""
        self.identityEmail = defaults.string(forKey: "identityEmail") ?? ""
        self.gitExecutablePath = defaults.string(forKey: GitProcess.gitExecutablePreferenceKey) ?? ""
        self.preferredEditor = defaults.string(forKey: "preferredEditor")
            .flatMap(ExternalEditor.init(rawValue:)) ?? .auto
        self.preferredTerminal = defaults.string(forKey: "preferredTerminal")
            .flatMap(ExternalTerminal.init(rawValue:)) ?? .terminal
    }

    @discardableResult
    public func addObserver(_ handler: @escaping (ChangeKind) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notify(_ kind: ChangeKind) {
        for handler in observers.values {
            handler(kind)
        }
    }
}
