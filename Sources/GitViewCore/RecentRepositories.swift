import Foundation

/// The repositories this user has opened, most recent first.
///
/// Stored as plain paths rather than security-scoped bookmarks: GitView is not sandboxed,
/// so a path is enough to reopen, and a path stays readable if someone edits the defaults
/// by hand. A folder that has since been moved or deleted is dropped on read rather than
/// offered and then failing.
public enum RecentRepositories {
    public static let limit = 10
    private static let key = "recentRepositories"
    private static let pinnedKey = "pinnedRepositories"

    /// Most recent first, excluding anything that is no longer a directory on disk.
    public static func all(defaults: UserDefaults = .standard) -> [URL] {
        existingDirectories(from: stored(defaults: defaults, forKey: key))
    }

    public static func pinned(defaults: UserDefaults = .standard) -> [URL] {
        existingDirectories(from: stored(defaults: defaults, forKey: pinnedKey))
    }

    public static func isPinned(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        let target = standardized(url)
        return pinned(defaults: defaults).contains { standardized($0) == target }
    }

    public static func pin(_ url: URL, defaults: UserDefaults = .standard) {
        let path = standardized(url)
        var paths = stored(defaults: defaults, forKey: pinnedKey).map(standardized)
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths, forKey: pinnedKey)
    }

    public static func unpin(_ url: URL, defaults: UserDefaults = .standard) {
        let path = standardized(url)
        defaults.set(
            stored(defaults: defaults, forKey: pinnedKey).map(standardized).filter { $0 != path },
            forKey: pinnedKey
        )
    }

    public static func togglePin(_ url: URL, defaults: UserDefaults = .standard) {
        if isPinned(url, defaults: defaults) {
            unpin(url, defaults: defaults)
        } else {
            pin(url, defaults: defaults)
        }
    }

    public static func ordered(defaults: UserDefaults = .standard) -> (pinned: [URL], recent: [URL]) {
        let pinnedURLs = pinned(defaults: defaults)
        let pinnedSet = Set(pinnedURLs.map(standardized))
        let recentURLs = all(defaults: defaults).filter { !pinnedSet.contains(standardized($0)) }
        return (pinnedURLs, recentURLs)
    }

    /// The one to reopen on launch, or nil on a first run.
    public static func last(defaults: UserDefaults = .standard) -> URL? {
        all(defaults: defaults).first
    }

    /// Moves `url` to the front, whether or not it was already known.
    public static func remember(_ url: URL, defaults: UserDefaults = .standard) {
        let path = standardized(url)
        var paths = stored(defaults: defaults, forKey: key).map(standardized)
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(limit)), forKey: key)
    }

    public static func forget(_ url: URL, defaults: UserDefaults = .standard) {
        let path = standardized(url)
        defaults.set(stored(defaults: defaults, forKey: key).map(standardized).filter { $0 != path }, forKey: key)
        unpin(url, defaults: defaults)
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    private static func existingDirectories(from urls: [URL]) -> [URL] {
        urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }

    private static func stored(defaults: UserDefaults, forKey storageKey: String) -> [URL] {
        (defaults.stringArray(forKey: storageKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Resolves symlinks so /tmp and /private/tmp — or two paths to the same clone — are
    /// one entry rather than two.
    private static func standardized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
