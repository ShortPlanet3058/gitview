import Foundation
import CoreServices

/// Watches a repository's `.git` directory and reports — debounced — that something in it
/// moved: a commit, a checkout, a fetch, a staged file, a stash.
///
/// Only `.git` is watched, not the working tree. A working tree holds build output
/// (`.build` alone is tens of thousands of files here), so watching it would mean a
/// constant stream of events that say nothing about the repository. Edits to tracked files
/// are picked up when the window comes forward instead, which is when anyone would look.
///
/// Git writes many files for one logical operation — a rebase touches HEAD, refs, the index
/// and several logs — so events are coalesced twice: by FSEvents' own latency window, and
/// again by a debounce here. What arrives is "something changed", never "what changed": the
/// model asks git that question, because only git can answer it correctly.
final class RepositoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.gitview.watcher", qos: .utility)
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    /// - Parameter onChange: called on an arbitrary queue, already debounced.
    init?(root: URL, debounce: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        self.debounce = debounce

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

    /// Collapses a burst of events into one call.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
