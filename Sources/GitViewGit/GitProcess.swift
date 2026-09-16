import Foundation

public enum GitError: Error, CustomStringConvertible {
    case gitNotExecutable(String)
    case notARepository(String)
    case failed(command: String, code: Int32, stderr: String)

    public var description: String {
        switch self {
        case .gitNotExecutable(let p):
            return "git is not executable at \(p)"
        case .notARepository(let p):
            return "not a git repository: \(p)"
        case .failed(let command, let code, let stderr):
            return "git \(command) exited \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Thin wrapper around `/usr/bin/git`.
///
/// The only subtle part is output handling. `git log -p` on a large repository emits
/// hundreds of megabytes; reading `standardOutput` only after `waitUntilExit()` deadlocks
/// as soon as the 64 KB pipe buffer fills and git blocks on write. So stdout is drained
/// continuously on a background queue and handed to the caller in chunks, and stderr is
/// drained on a separate thread so it cannot fill and block either.
public enum GitProcess {
    public static let gitPath = "/usr/bin/git"

    /// Streams stdout to `onOutput` in arbitrary chunks (not line-aligned).
    ///
    /// `onOutput` is invoked serially on a background queue and is guaranteed to have
    /// finished for all chunks before this function returns.
    public static func stream(
        arguments: [String],
        in directory: URL,
        onOutput: @escaping @Sendable (Data) -> Void
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: gitPath) else {
            throw GitError.gitNotExecutable(gitPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Keep git's output stable regardless of the user's global config.
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outEOF = DispatchSemaphore(value: 0)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outEOF.signal()
            } else {
                onOutput(data)
            }
        }

        let stderrBox = DataBox()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            errGroup.leave()
        }

        try process.run()

        // Wait for EOF on both streams *before* waitUntilExit, then reap.
        outEOF.wait()
        errGroup.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitError.failed(
                command: arguments.joined(separator: " "),
                code: process.terminationStatus,
                stderr: String(decoding: stderrBox.get(), as: UTF8.self)
            )
        }
    }

    /// Runs git and returns its complete stdout. Only for small, bounded outputs.
    public static func capture(arguments: [String], in directory: URL) throws -> String {
        let box = DataBox()
        try stream(arguments: arguments, in: directory) { box.append($0) }
        return String(decoding: box.get(), as: UTF8.self)
    }
}

/// Minimal lock-guarded `Data` accumulator, so buffers can cross queue boundaries
/// under Swift 6 strict concurrency checking.
final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func set(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        data = value
    }

    func get() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
