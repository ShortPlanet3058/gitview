import Foundation

/// A single write or mutation `git` invocation executed for a repository.
public struct GitCommandRecord: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let directory: URL
    public let arguments: [String]
    public let duration: TimeInterval
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public var commandLine: String {
        "git " + arguments.map(Self.shellQuote).joined(separator: " ")
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        directory: URL,
        arguments: [String],
        duration: TimeInterval,
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.directory = directory
        self.arguments = arguments
        self.duration = duration
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public static func shellQuote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safeScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:=@+%"))
        let needsQuoting = argument.unicodeScalars.contains { !safeScalars.contains($0) }
        guard needsQuoting else { return argument }
        let escaped = argument.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

/// Thread-safe in-memory log of recent `git` commands run by `GitWriter`.
public final class GitCommandRecorder: @unchecked Sendable {
    public static let shared = GitCommandRecorder()
    public static let maxStoredRecords = 200
    public static let maxOutputBytes = 16 * 1024

    private let lock = NSLock()
    private var entries: [GitCommandRecord] = []
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public func record(_ entry: GitCommandRecord) {
        let clamped = GitCommandRecord(
            id: entry.id,
            timestamp: entry.timestamp,
            directory: entry.directory.resolvingSymlinksInPath().standardizedFileURL,
            arguments: entry.arguments,
            duration: entry.duration,
            exitCode: entry.exitCode,
            stdout: Self.truncateOutput(entry.stdout),
            stderr: Self.truncateOutput(entry.stderr)
        )
        let handlers: [@Sendable () -> Void]
        lock.lock()
        entries.insert(clamped, at: 0)
        if entries.count > Self.maxStoredRecords {
            entries.removeLast(entries.count - Self.maxStoredRecords)
        }
        handlers = Array(observers.values)
        lock.unlock()

        for handler in handlers {
            handler()
        }
    }

    public func records(for directory: URL? = nil) -> [GitCommandRecord] {
        let targetPath = directory?.resolvingSymlinksInPath().standardizedFileURL.path
        lock.lock()
        let snapshot = entries
        lock.unlock()

        guard let targetPath else { return snapshot }
        return snapshot.filter { $0.directory.path == targetPath }
    }

    public func clear(for directory: URL? = nil) {
        let targetPath = directory?.resolvingSymlinksInPath().standardizedFileURL.path
        let handlers: [@Sendable () -> Void]
        lock.lock()
        if let targetPath {
            entries.removeAll { $0.directory.path == targetPath }
        } else {
            entries.removeAll()
        }
        handlers = Array(observers.values)
        lock.unlock()

        for handler in handlers {
            handler()
        }
    }

    @discardableResult
    public func addObserver(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    public static func truncateOutput(_ text: String) -> String {
        guard text.utf8.count > maxOutputBytes else { return text }
        var end = text.utf8.index(text.startIndex, offsetBy: maxOutputBytes)
        while end > text.startIndex && end.samePosition(in: text) == nil {
            end = text.utf8.index(before: end)
        }
        return String(text[..<end]) + "\n… (truncated)"
    }
}
