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

    /// - Parameter since: when set, reads only commits after this one.
    public func loadHistory(since: String? = nil) throws -> [Commit] {
        let arguments = [
            // Stop git from octal-escaping non-ASCII paths, so UTF-8 filenames survive intact.
            "-c", "core.quotePath=false",
            "log",
            "--unified=0",       // every @@ header covers exactly the changed lines
            "--no-color",
            "--find-renames",
            // Fields are separated by 0x1F (ASCII unit separator, `%x1f`) rather than `|`:
            // author names and subjects both contain pipes in real histories.
            //
            // `%aN`, not `%an`: the capital form resolves the author through .mailmap, so a
            // person who has committed as "Johannes Weiss" and "Johannes Weiß" is one
            // contributor rather than two. swift-nio ships a 4.8 KB mailmap; ignoring it
            // split its top contributor's 769 commits into 589 + 180.
            "--pretty=format:@@@%H%x1f%aN%x1f%aI%x1f%s",
            "-p",
        ] + (since.map { ["\($0)..HEAD"] } ?? [])

        let sink = ParserBox()
        try GitProcess.stream(arguments: arguments, in: url) { chunk in
            sink.feed(chunk)
        }
        return sink.finish()
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
