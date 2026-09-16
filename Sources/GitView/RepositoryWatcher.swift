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
final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.gitview.watcher", qos: .utility)
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    /// - Parameter onChange: called on an arbitrary queue, already debounced.
    init?(root: URL, debounce: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        self.debounce = debounce

        // A worktree or submodule has a `.git` *file* pointing elsewhere; watching the file
        // would miss everything. Fall back to the repository root in that case, which is
        // noisier but correct.
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory)
        let watched = (exists && isDirectory.boolValue) ? dotGit : root
        guard exists || FileManager.default.fileExists(atPath: root.path) else { return nil }

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
            [watched.path] as CFArray,
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
