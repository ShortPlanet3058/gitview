import Foundation
import CoreServices

/// Watches a repository's `.git` directory (for commits, checkouts, fetches, staging, stashes)
/// and optionally the working tree (for side-by-side editor saves on dual-monitor setups),
/// filtering out `.git` and noisy build/cache folders before debouncing callbacks.
final class RepositoryWatcher: @unchecked Sendable {
    private static let ignoredWorktreeSegments: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules", ".swiftpm",
        "Pods", "Carthage", "target", "dist", "build", ".next", ".nuxt",
        ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache",
        ".gradle", ".idea", ".DS_Store", "xcuserdata",
    ]

    private var stream: FSEventStreamRef?
    private var worktreeStream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.gitview.watcher", qos: .utility)
    private var pending: DispatchWorkItem?
    private var pendingWorktree: DispatchWorkItem?
    private let debounce: TimeInterval
    private let worktreeDebounce: TimeInterval
    private let resolvedRootPath: String
    private let onChange: @Sendable () -> Void
    private let onWorktreeChange: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - onChange: called on an arbitrary queue after `.git` activity, already debounced.
    ///   - onWorktreeChange: optional debounced callback when non-ignored working-tree files change.
    init?(
        root: URL,
        debounce: TimeInterval = 0.5,
        worktreeDebounce: TimeInterval = 0.7,
        onChange: @escaping @Sendable () -> Void,
        onWorktreeChange: (@Sendable () -> Void)? = nil
    ) {
        self.onChange = onChange
        self.onWorktreeChange = onWorktreeChange
        self.debounce = debounce
        self.worktreeDebounce = worktreeDebounce
        self.resolvedRootPath = root.standardizedFileURL.resolvingSymlinksInPath().path

        let watched = Self.watchedDirectories(for: root)
        guard !watched.isEmpty else { return nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            watched.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return nil
        }

        if onWorktreeChange != nil {
            var worktreeContext = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)

            let worktreeCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                watcher.handleWorktreeEvents(paths)
            }

            if let wtStream = FSEventStreamCreate(
                kCFAllocatorDefault, worktreeCallback, &worktreeContext,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,
                UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
            {
                FSEventStreamSetDispatchQueue(wtStream, queue)
                if FSEventStreamStart(wtStream) {
                    self.worktreeStream = wtStream
                } else {
                    FSEventStreamInvalidate(wtStream)
                    FSEventStreamRelease(wtStream)
                }
            }
        }
    }

    /// True when a working-tree path belongs to `.git` or an ignored build/cache directory.
    static func shouldIgnoreWorktreePath(_ path: String, relativeTo rootPath: String) -> Bool {
        let normalizedRoot = normalize(path: rootPath)
        let normalizedPath = normalize(path: path)

        let relative: String
        if normalizedPath == normalizedRoot {
            return true
        } else if normalizedPath.hasPrefix(normalizedRoot + "/") {
            relative = String(normalizedPath.dropFirst(normalizedRoot.count + 1))
        } else {
            let resolvedRoot = normalize(path: URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath().path)
            let resolvedPath = normalize(path: URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path)
            if resolvedPath == resolvedRoot {
                return true
            } else if resolvedPath.hasPrefix(resolvedRoot + "/") {
                relative = String(resolvedPath.dropFirst(resolvedRoot.count + 1))
            } else {
                relative = normalizedPath
            }
        }

        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return true }
        for segment in components {
            if ignoredWorktreeSegments.contains(segment) {
                return true
            }
            if segment.hasSuffix(".xcuserdatad") || segment.hasSuffix(".xcuserstate") {
                return true
            }
        }
        return false
    }

    private static func normalize(path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    /// Resolves `.git` directories to watch, handling worktrees and submodules where `.git` is
    /// a `gitdir:` pointer file rather than a directory.
    static func watchedDirectories(for root: URL) -> [URL] {
        let fm = FileManager.default
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return fm.fileExists(atPath: root.path) ? [root] : []
        }
        if isDirectory.boolValue { return [dotGit] }

        if let text = try? String(contentsOf: dotGit, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawPath.isEmpty {
                let gitDir = URL(fileURLWithPath: rawPath, relativeTo: root).standardizedFileURL
                var dirs: [URL] = [gitDir]
                let commonFile = gitDir.appendingPathComponent("commondir")
                if let commonRaw = try? String(contentsOf: commonFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !commonRaw.isEmpty {
                    let commonDir = URL(fileURLWithPath: commonRaw, relativeTo: gitDir).standardizedFileURL
                    if commonDir.path != gitDir.path { dirs.append(commonDir) }
                }
                let existing = dirs.filter {
                    var isDir: ObjCBool = false
                    return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
                }
                if !existing.isEmpty { return existing }
            }
        }
        return [root]
    }

    /// Collapses a burst of `.git` events into one call.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func handleWorktreeEvents(_ paths: [String]) {
        guard onWorktreeChange != nil else { return }
        let hasRelevantChange = paths.contains { !Self.shouldIgnoreWorktreePath($0, relativeTo: resolvedRootPath) }
        guard hasRelevantChange else { return }
        scheduleWorktree()
    }

    private func scheduleWorktree() {
        guard let onWorktreeChange else { return }
        pendingWorktree?.cancel()
        let work = DispatchWorkItem { onWorktreeChange() }
        pendingWorktree = work
        queue.asyncAfter(deadline: .now() + worktreeDebounce, execute: work)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        pendingWorktree?.cancel()
        pendingWorktree = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if let worktreeStream {
            FSEventStreamStop(worktreeStream)
            FSEventStreamInvalidate(worktreeStream)
            FSEventStreamRelease(worktreeStream)
            self.worktreeStream = nil
        }
    }

    deinit { stop() }
}
