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

    /// Most recent first, excluding anything that is no longer a directory on disk.
    public static func all(defaults: UserDefaults = .standard) -> [URL] {
        stored(defaults: defaults).filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }

    /// The one to reopen on launch, or nil on a first run.
    public static func last(defaults: UserDefaults = .standard) -> URL? {
        all(defaults: defaults).first
    }

    /// Moves `url` to the front, whether or not it was already known.
    public static func remember(_ url: URL, defaults: UserDefaults = .standard) {
        let path = standardized(url)
        var paths = stored(defaults: defaults).map(standardized)
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(limit)), forKey: key)
    }

    public static func forget(_ url: URL, defaults: UserDefaults = .standard) {
        let path = standardized(url)
        defaults.set(stored(defaults: defaults).map(standardized).filter { $0 != path }, forKey: key)
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    private static func stored(defaults: UserDefaults) -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Resolves symlinks so /tmp and /private/tmp — or two paths to the same clone — are
    /// one entry rather than two.
    private static func standardized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
