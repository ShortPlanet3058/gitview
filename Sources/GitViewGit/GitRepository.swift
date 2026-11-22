import Foundation
import GitViewCore

/// Reads a local repository's history via a single `git log` invocation.
public struct GitRepository: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Verifies the path is inside a work tree and returns the repository root.
    public func validate() throws -> URL {
        let inside = try GitProcess.capture(arguments: ["rev-parse", "--is-inside-work-tree"], in: url)
        guard inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw GitError.notARepository(url.path)
        }
        let root = try GitProcess.capture(arguments: ["rev-parse", "--show-toplevel"], in: url)
        return URL(fileURLWithPath: root.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One repo-wide `git log` covering the whole reachable history of HEAD.
    ///
    /// Merge commits appear with no diff, because `git log -p` does not show patches for
    /// merges unless asked. That is deliberate: showing them would double-count every
    /// change that came in through a merge.
    public func headSHA() throws -> String {
        try GitProcess.capture(arguments: ["rev-parse", "HEAD"], in: url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `ancestor` is reachable from `descendant`, so commits can safely be read
    /// as a range. False after a rebase or force-push, where the old tip is no longer in
    /// history and an incremental read would silently lose commits.
    public func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
        (try? GitProcess.capture(arguments: ["merge-base", "--is-ancestor", ancestor, descendant], in: url)) != nil
    }

    /// How many commits `to` has that `from` does not — `git rev-list --count from..to`.
    ///
    /// Counting this way costs a graph walk and nothing else. Asking `loadHistory` and
    /// taking `.count` would read every patch in the range to answer a question about
    /// arithmetic, which is what makes the difference between instant and seconds when
    /// something is only checking whether the repository moved.
    public func commitCount(from: String, to: String) -> Int {
        guard let output = try? GitProcess.capture(
            arguments: ["rev-list", "--count", "\(from)..\(to)"], in: url) else { return 0 }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Commit hashes reachable from HEAD, newest first, without reading patches.
    public func revListSHAs() -> [String]? {
        guard let output = try? GitProcess.capture(arguments: ["rev-list", "HEAD"], in: url) else {
            return nil
        }
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// - Parameter since: when set, reads only commits after this one.
    public func loadHistory(since: String? = nil) throws -> [Commit] {
        try loadHistory(range: since.map { "\($0)..HEAD" })
    }

    /// - Parameter range: a git revision range such as `v1.0..v2.0`. Nil reads all of HEAD.
    public func loadHistory(range: String?) throws -> [Commit] {
        let sink = ParserBox()
        try GitProcess.stream(arguments: historyArguments(range: range), in: url) { chunk in
            sink.feed(chunk)
        }
        return sink.finish()
    }

    /// Async, cancellable equivalent of `loadHistory(since:)`. Cancelling the calling
    /// task immediately terminates the underlying `git log` process.
    public func loadHistoryAsync(since: String? = nil) async throws -> [Commit] {
        try await loadHistoryAsync(range: since.map { "\($0)..HEAD" })
    }

    /// Async, cancellable equivalent of `loadHistory(range:)`.
    public func loadHistoryAsync(range: String?) async throws -> [Commit] {
        let sink = ParserBox()
        try await GitProcess.streamAsync(arguments: historyArguments(range: range), in: url) { chunk in
            sink.feed(chunk)
        }
        return sink.finish()
    }

    private func historyArguments(range: String?) -> [String] {
        [
            // Stop git from octal-escaping non-ASCII paths, so UTF-8 filenames survive intact.
            "-c", "core.quotePath=false",
            "log",
            "--unified=0",       // every @@ header covers exactly the changed lines
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "--diff-merges=off",
            "--find-renames",
            // Fields are separated by 0x1F (ASCII unit separator, `%x1f`) rather than `|`:
            // author names and subjects both contain pipes in real histories.
            //
            // `%aN` / `%aE`: capital forms resolve through .mailmap so contributor aliases unify.
            "--pretty=format:@@@%H%x1f%aN%x1f%aE%x1f%aI%x1f%s",
            "-p",
        ] + (range.map { [$0] } ?? [])
    }
}

/// Owns the splitter and parser so they can be mutated from the reader queue while
/// remaining safe to hand across concurrency domains.
private final class ParserBox: @unchecked Sendable {
    private var splitter = LineSplitter()
    private var parser = GitLogParser()
    private let lock = NSLock()

    func feed(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        splitter.feed(chunk) { parser.consume(line: $0) }
    }

    func finish() -> [Commit] {
        lock.lock(); defer { lock.unlock() }
        splitter.finish { parser.consume(line: $0) }
        return parser.finish()
    }
}
