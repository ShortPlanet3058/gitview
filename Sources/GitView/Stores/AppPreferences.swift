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

public enum DiffLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case unified = "Unified"
    case sideBySide = "Side by side"

    public var id: String { rawValue }
}

public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum AutoFetchInterval: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .fiveMinutes: return "Every 5 minutes"
        case .fifteenMinutes: return "Every 15 minutes"
        case .thirtyMinutes: return "Every 30 minutes"
        }
    }
}

/// Persisted application-wide settings shared across windows and observed by sessions.
@MainActor
@Observable
public final class AppPreferences {
    public static let defaultCodeFontSize: Double = 11
    public static let codeFontSizeRange: ClosedRange<Double> = 9...18

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

    public var diffLayoutMode: DiffLayoutMode {
        didSet {
            defaults.set(diffLayoutMode.rawValue, forKey: "diffLayoutMode")
            notify(.environment)
        }
    }

    public var diffIgnoreWhitespace: Bool {
        didSet {
            defaults.set(diffIgnoreWhitespace, forKey: "diffIgnoreWhitespace")
            notify(.environment)
        }
    }

    public var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
            notify(.environment)
        }
    }

    public var codeFontSize: Double {
        didSet {
            let clamped = min(max(codeFontSize, Self.codeFontSizeRange.lowerBound), Self.codeFontSizeRange.upperBound)
            if clamped != codeFontSize {
                codeFontSize = clamped
                return
            }
            defaults.set(codeFontSize, forKey: "codeFontSize")
            notify(.environment)
        }
    }

    public var wrapCodeLines: Bool {
        didSet {
            defaults.set(wrapCodeLines, forKey: "wrapCodeLines")
            notify(.environment)
        }
    }

    public var autoFetchInterval: AutoFetchInterval {
        didSet {
            defaults.set(autoFetchInterval.rawValue, forKey: "autoFetchInterval")
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
        self.diffLayoutMode = defaults.string(forKey: "diffLayoutMode")
            .flatMap(DiffLayoutMode.init(rawValue:)) ?? .unified
        self.diffIgnoreWhitespace = defaults.bool(forKey: "diffIgnoreWhitespace")
        self.appearanceMode = defaults.string(forKey: "appearanceMode")
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        let storedFontSize = defaults.object(forKey: "codeFontSize") as? Double ?? Self.defaultCodeFontSize
        self.codeFontSize = min(max(storedFontSize, Self.codeFontSizeRange.lowerBound), Self.codeFontSizeRange.upperBound)
        self.wrapCodeLines = defaults.object(forKey: "wrapCodeLines") as? Bool ?? true
        let storedAutoFetch = defaults.object(forKey: "autoFetchInterval") as? Int ?? 0
        self.autoFetchInterval = AutoFetchInterval(rawValue: storedAutoFetch) ?? .off
    }

    public func increaseCodeFontSize() {
        codeFontSize = min(codeFontSize + 1, Self.codeFontSizeRange.upperBound)
    }

    public func decreaseCodeFontSize() {
        codeFontSize = max(codeFontSize - 1, Self.codeFontSizeRange.lowerBound)
    }

    public func resetCodeFontSize() {
        codeFontSize = Self.defaultCodeFontSize
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
