import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

/// Thin wrapper around the `git` CLI.
///
/// The only subtle part is output handling. `git log -p` on a large repository emits
/// hundreds of megabytes; reading `standardOutput` only after `waitUntilExit()` deadlocks
/// as soon as the 64 KB pipe buffer fills and git blocks on write. So stdout is drained
/// continuously on a background queue and handed to the caller in chunks, and stderr is
/// drained separately so it cannot fill and block either.
public enum GitProcess {
    public static let gitExecutablePreferenceKey = "gitExecutablePath"

    private static let candidateGitPaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git",
    ]

    private static let ignoreSigpipeOnce: Void = {
        #if canImport(Darwin)
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        #endif
    }()

    /// Resolves the `git` binary: user override (if executable), then Homebrew/system paths.
    public static var gitPath: String {
        if let custom = UserDefaults.standard.string(forKey: gitExecutablePreferenceKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        for path in candidateGitPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/git"
    }

    private static func configuredProcess(
        executable: String,
        arguments: [String],
        directory: URL
    ) -> Process {
        _ = ignoreSigpipeOnce
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Keep git's output stable regardless of the user's global config.
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        return process
    }

    private static func writeStdinAsync(_ data: Data, to pipe: Pipe) {
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = pipe.fileHandleForWriting
            defer { try? handle.close() }
            if !data.isEmpty {
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Streams stdout to `onOutput` in arbitrary chunks (not line-aligned).
    ///
    /// `onOutput` is invoked serially on a background queue and is guaranteed to have
    /// finished for all chunks before this function returns.
    public static func stream(
        arguments: [String],
        stdin: Data? = nil,
        in directory: URL,
        onOutput: @escaping @Sendable (Data) -> Void
    ) throws {
        let executable = gitPath
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw GitError.gitNotExecutable(executable)
        }

        let process = configuredProcess(executable: executable, arguments: arguments, directory: directory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var inPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        }

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

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            try? inPipe?.fileHandleForWriting.close()
            throw error
        }

        if let stdin, let inPipe {
            writeStdinAsync(stdin, to: inPipe)
        }

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
    @discardableResult
    public static func capture(
        arguments: [String],
        stdin: Data? = nil,
        in directory: URL
    ) throws -> String {
        let box = DataBox()
        try stream(arguments: arguments, stdin: stdin, in: directory) { box.append($0) }
        return String(decoding: box.get(), as: UTF8.self)
    }

    /// Cancellable async variant of `stream(arguments:stdin:in:onOutput:)`.
    /// Cancelling the enclosing `Task` immediately terminates the child `git` process.
    public static func streamAsync(
        arguments: [String],
        stdin: Data? = nil,
        in directory: URL,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws {
        try Task.checkCancellation()
        let executable = gitPath
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw GitError.gitNotExecutable(executable)
        }

        let box = ProcessBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = configuredProcess(executable: executable, arguments: arguments, directory: directory)
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                var inPipe: Pipe?
                if stdin != nil {
                    let pipe = Pipe()
                    process.standardInput = pipe
                    inPipe = pipe
                }

                let stderrBox = DataBox()
                let doneGroup = DispatchGroup()
                let closeState = StreamCloseState()
                let resumeGate = ResumeGate()

                doneGroup.enter()
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        if closeState.markStdoutClosed() { doneGroup.leave() }
                    } else if !box.isCancelled {
                        onOutput(data)
                    }
                }

                doneGroup.enter()
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        if closeState.markStderrClosed() { doneGroup.leave() }
                    } else if !box.isCancelled {
                        stderrBox.append(data)
                    }
                }

                doneGroup.enter()
                process.terminationHandler = { _ in
                    doneGroup.leave()
                    if box.isCancelled {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        box.detach()
                        resumeGate.resumeOnce {
                            continuation.resume(throwing: CancellationError())
                        }
                    }
                }

                guard box.attachIfActive(process) else {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    try? inPipe?.fileHandleForWriting.close()
                    resumeGate.resumeOnce {
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }

                do {
                    try process.run()
                } catch {
                    box.detach()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    try? inPipe?.fileHandleForWriting.close()
                    resumeGate.resumeOnce {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                if box.isCancelled && process.isRunning {
                    process.terminate()
                }

                if let stdin, let inPipe {
                    writeStdinAsync(stdin, to: inPipe)
                }

                doneGroup.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    box.detach()
                    resumeGate.resumeOnce {
                        if box.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if process.terminationStatus == 0 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: GitError.failed(
                                command: arguments.joined(separator: " "),
                                code: process.terminationStatus,
                                stderr: String(decoding: stderrBox.get(), as: UTF8.self)
                            ))
                        }
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Cancellable async variant of `capture(arguments:stdin:in:)`.
    @discardableResult
    public static func captureAsync(
        arguments: [String],
        stdin: Data? = nil,
        in directory: URL
    ) async throws -> String {
        let box = DataBox()
        try await streamAsync(arguments: arguments, stdin: stdin, in: directory) { box.append($0) }
        return String(decoding: box.get(), as: UTF8.self)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func attachIfActive(_ proc: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        process = proc
        return true
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        process = nil
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let proc = process
        lock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }
}

private final class StreamCloseState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutClosed = false
    private var stderrClosed = false

    func markStdoutClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stdoutClosed else { return false }
        stdoutClosed = true
        return true
    }

    func markStderrClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stderrClosed else { return false }
        stderrClosed = true
        return true
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        body()
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
